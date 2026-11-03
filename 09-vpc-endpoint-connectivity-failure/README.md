# Lab 09 — VPC Endpoint Connectivity Failure

## Overview

This lab demonstrates how to troubleshoot an AWS interface VPC endpoint connectivity failure caused by an incorrectly configured security group.

We deploy an Amazon EC2 instance in a private subnet without a public IPv4 address, Internet Gateway, or NAT Gateway.

The instance connects privately to AWS Systems Manager using interface VPC endpoints powered by AWS PrivateLink.

Initially, both endpoints work correctly. We then intentionally remove the inbound HTTPS rule from the Systems Manager endpoint's security group.

Even though the endpoint remains available and private DNS is enabled, new HTTPS connections to the affected endpoint fail.

We investigate the failure, identify the missing security group rule, restore least-privilege access, verify connectivity, and clean up the environment.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-009 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, Systems Manager, IAM, PrivateLink |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Linux networking utilities |
| VPC CIDR | `10.90.0.0/16` |
| Private Subnet | `10.90.1.0/24` |
| EC2 Public IPv4 | None |
| Internet Gateway | None |
| NAT Gateway | None |
| VPC Endpoint Type | Interface |
| SSM Endpoint | `com.amazonaws.us-east-1.ssm` |
| Messaging Endpoint | `com.amazonaws.us-east-1.ssmmessages` |
| Endpoint Protocol | HTTPS, TCP 443 |
| Simulated Failure | Missing SSM endpoint inbound rule |
| Root Cause | Endpoint security group blocks TCP 443 |
| Remediation | Restore inbound TCP 443 from EC2 SG |
| Management | Systems Manager Session Manager |

---

## 2. Production Incident Scenario

A company hosts internal application servers inside private AWS subnets.

For security reasons, these instances do not have public IPv4 addresses and cannot access the public internet directly.

Instead, the company uses AWS PrivateLink interface endpoints to provide private access to Systems Manager.

Following a security group configuration change, communication with the Systems Manager service endpoint begins failing.

The cloud engineer finds that:

- EC2 is running.
- VPC routing is correct.
- VPC DNS resolution is enabled.
- Interface endpoints exist.
- Private DNS is enabled.
- The endpoint state is `available`.
- The EC2 security group allows outbound connections.
- The SSM endpoint security group is missing an inbound TCP 443 rule.
- The `ssmmessages` endpoint remains reachable.

### Expected Behavior

```text
Private EC2
     |
     | HTTPS TCP 443
     v
SSM Endpoint Security Group
     |
     | ALLOW
     v
Interface Endpoint ENI
     |
     v
AWS Systems Manager
```

### Failure Behavior

```text
Private EC2
     |
     | HTTPS TCP 443
     v
SSM Endpoint Security Group
     |
     X
Inbound Rule Missing
     |
     X
New HTTPS Connection Fails
```

### Potential Business Impact

- Systems Manager agent operations fail.
- Remote administration becomes unreliable.
- Inventory and compliance reporting may be affected.
- Automated management operations fail.
- Maintenance and troubleshooting become more difficult.
- Monitoring visibility may decrease.

### Incident Objective

Restore private connectivity to the Systems Manager endpoint without introducing public internet access.

---

## 3. AWS Architecture

```text
                     AWS Region: us-east-1
                              |
               +-------------------------------+
               | AWS VPC                       |
               | 10.90.0.0/16                  |
               |                               |
               | Private Subnet                |
               | 10.90.1.0/24                  |
               |                               |
               |       Private EC2             |
               |       No Public IPv4          |
               |       EC2 Security Group      |
               |               |               |
               |        HTTPS TCP 443          |
               |               |               |
               |       +-------+-------+       |
               |       |               |       |
               |       v               v       |
               |   SSM Endpoint    Messages    |
               |   Private ENI     Endpoint    |
               |       |           Private ENI |
               |       X               |       |
               |   SG BLOCKS 443   SG ALLOWS   |
               |                               |
               +-------------------------------+

              No Internet Gateway
              No NAT Gateway
```

### Network Components

| Component | Purpose |
|---|---|
| VPC | Isolated networking environment |
| Private subnet | Hosts EC2 and endpoint interfaces |
| Private EC2 | Simulated production workload |
| EC2 SG | Permits outbound connections |
| SSM interface endpoint | Provides private access to SSM API |
| SSM Messages endpoint | Supports Session Manager communication |
| Endpoint ENIs | Private network interfaces for supported services |
| Endpoint SGs | Control connections to endpoint ENIs |
| AmazonProvidedDNS | Resolves service names to endpoint IPs |
| IAM instance profile | Grants SSM Agent permissions |

### Healthy Network Path

```text
EC2 Instance
    |
    v
EC2 Security Group
    |
    v
VPC Local Routing
    |
    v
Endpoint Security Group
    |
    v
Interface Endpoint ENI
    |
    v
AWS Service
```

### Important Architecture Notes

Interface endpoints use private network interfaces inside the VPC.

They do not require an Internet Gateway or NAT Gateway to connect privately to supported AWS services.

With private DNS enabled, the normal AWS service hostname resolves to private IP addresses associated with the endpoint.

This lab uses `ssm` and `ssmmessages`. Other Systems Manager features or older regional configurations may require additional endpoints such as `ec2messages`, S3, or CloudWatch Logs.

---

## 4. Understanding Interface VPC Endpoints

An interface VPC endpoint provides private connectivity to a supported AWS service using AWS PrivateLink.

AWS creates one or more endpoint network interfaces in selected subnets.

Each interface has a private IPv4 address.

Workloads access the service through these interfaces without requiring public internet access.

### Interface Endpoint Characteristics

- Uses private network interfaces.
- Supports security groups.
- Can enable private DNS.
- Connects to supported AWS services privately.
- May incur hourly and data-processing charges.
- Uses VPC-local networking for the endpoint connection.

### Interface Endpoint vs. Gateway Endpoint

| Feature | Interface Endpoint | Gateway Endpoint |
|---|---|---|
| Technology | AWS PrivateLink | Gateway endpoint routing |
| Network Interfaces | Yes | No endpoint ENI |
| Security Groups | Yes | No endpoint SG |
| Route Table Entry | Usually not required | Required |
| Private DNS | Often supported | Different service-specific behavior |
| Typical Services | SSM, KMS, Secrets Manager | S3, DynamoDB |
| Hourly Endpoint Charge | Yes | No endpoint hourly charge |

### Endpoint Security Groups

The endpoint security group must allow the required inbound traffic from the consuming workload.

For this lab:

```text
Protocol: TCP
Port:     443
Source:   EC2 Security Group
```

A healthy endpoint resource does not automatically mean network traffic is permitted.

---

## 5. Prerequisites and Safety

### Required

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- IAM permissions
- EC2 and VPC permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated VPC.
- Do not modify shared endpoint security groups.
- Keep EC2 inbound rules empty.
- Use private IP connectivity only.
- Do not add public internet routes.
- Restrict endpoint inbound access to the EC2 security group.
- Verify ownership before deleting infrastructure.

### Cost Warning

Interface VPC endpoints incur hourly and data-processing charges.

The lab also creates an EC2 instance and EBS volume.

**Delete both interface endpoints after completing the exercise to avoid unnecessary charges.**

---

## 6. Prepare the AWS Environment

Run all AWS CLI infrastructure commands in Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab09"

export VPC_CIDR="10.90.0.0/16"
export SUBNET_CIDR="10.90.1.0/24"

export VPC_NAME="cloud-lab09-vpc"
export SUBNET_NAME="cloud-lab09-private-subnet"

export EC2_SG_NAME="cloud-lab09-ec2-sg"
export SSM_SG_NAME="cloud-lab09-ssm-endpoint-sg"
export MSG_SG_NAME="cloud-lab09-messages-endpoint-sg"

export INSTANCE_NAME="cloud-lab09-private-ec2"

export ROLE_NAME="cloud-lab09-ssm-role"
export PROFILE_NAME="cloud-lab09-ssm-profile"

export SSM_SERVICE="com.amazonaws.${AWS_REGION}.ssm"
export MSG_SERVICE="com.amazonaws.${AWS_REGION}.ssmmessages"
```

Verify identity:

```bash
aws sts get-caller-identity
```

### Step 2 — Check Availability Zone Support

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Check endpoint services:

```bash
aws ec2 describe-vpc-endpoint-services \
  --service-names "$SSM_SERVICE" "$MSG_SERVICE" \
  --query 'ServiceDetails[].{Service:ServiceName,AZs:AvailabilityZones}' \
  --output json \
  --region "$AWS_REGION"
```

Choose an AZ supported by EC2 and both endpoint services:

```bash
export LAB_AZ="us-east-1a"
```

### Step 3 — Check Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create duplicate infrastructure if an existing Lab 09 VPC needs to be reused or cleaned up.

---

## 7. Create Private VPC

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Enable DNS Support

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"
```

### Step 3 — Enable DNS Hostnames

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 4 — Create Private Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

Disable automatic public IPv4 assignment:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --no-map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 5 — Verify Local Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
10.90.0.0/16 → local
```

There is no internet route.

---

## 8. Configure Security Groups

### Step 1 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name "$EC2_SG_NAME" \
  --description "Lab09 private EC2 security group" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create SSM Endpoint Security Group

```bash
export SSM_SG_ID=$(aws ec2 create-security-group \
  --group-name "$SSM_SG_NAME" \
  --description "Lab09 SSM interface endpoint security group" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Messaging Endpoint Security Group

```bash
export MSG_SG_ID=$(aws ec2 create-security-group \
  --group-name "$MSG_SG_NAME" \
  --description "Lab09 SSM messages endpoint security group" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Tag the security groups:

```bash
aws ec2 create-tags \
  --resources "$EC2_SG_ID" "$SSM_SG_ID" "$MSG_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 4 — Allow TCP 443 to SSM Endpoint

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SSM_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Allow TCP 443 to Messaging Endpoint

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$MSG_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Initial Security Group Configuration

| Security Group | Inbound | Outbound |
|---|---|---|
| EC2 SG | No rules | Default allow |
| SSM endpoint SG | TCP 443 from EC2 SG | Default allow |
| Messages endpoint SG | TCP 443 from EC2 SG | Default allow |

---

## 9. Create Interface VPC Endpoints

### Step 1 — Create SSM Endpoint

```bash
export SSM_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "$SSM_SERVICE" \
  --subnet-ids "$SUBNET_ID" \
  --security-group-ids "$SSM_SG_ID" \
  --private-dns-enabled \
  --tag-specifications \
    "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=cloud-lab09-ssm-endpoint},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Session Messages Endpoint

```bash
export MSG_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface \
  --service-name "$MSG_SERVICE" \
  --subnet-ids "$SUBNET_ID" \
  --security-group-ids "$MSG_SG_ID" \
  --private-dns-enabled \
  --tag-specifications \
    "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=cloud-lab09-messages-endpoint},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Endpoint Availability

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Service:ServiceName,State:State,PrivateDNS:PrivateDnsEnabled}' \
  --output table \
  --region "$AWS_REGION"
```

Proceed when both endpoints report `available`.

Expected:

```text
SSM Endpoint      available    PrivateDNS=True
Messages Endpoint available    PrivateDNS=True
```

### Step 4 — Inspect Endpoint Network Interfaces

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{Service:ServiceName,Interfaces:NetworkInterfaceIds}' \
  --output json \
  --region "$AWS_REGION"
```

The endpoints use network interfaces with private IPv4 addresses.

---

## 10. Configure IAM for Systems Manager

### Step 1 — Create Trust Policy

Create `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 2 — Check Existing IAM Resources

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

`NoSuchEntity` is expected for unused names.

### Step 3 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 4 — Attach SSM Managed Policy

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 5 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM propagation before launching EC2.

---

## 11. Prepare Endpoint Connectivity Monitoring

We use a background probe because changing the endpoint security group could affect Systems Manager connectivity.

Create `endpoint-probe.sh`:

```bash
#!/bin/bash
set -eu

cat > /usr/local/bin/lab09-check.sh <<'SCRIPT'
#!/bin/bash
LOG="/var/tmp/vpc-lab09-probe.log"
REGION="us-east-1"

for i in $(seq 1 120); do
  echo "Time: $(date -u +%FT%TZ)" >> "$LOG"

  for SERVICE in ssm ssmmessages; do
    HOST="${SERVICE}.${REGION}.amazonaws.com"

    CODE=$(curl -4 -s \
      --noproxy '*' \
      --connect-timeout 3 \
      --max-time 5 \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${HOST}/" || true)

    if [ "$CODE" != "000" ] && [ -n "$CODE" ]; then
      echo "${SERVICE}=HTTPS_REACHABLE HTTP_${CODE}" >> "$LOG"
    else
      echo "${SERVICE}=CONNECT_FAILED" >> "$LOG"
    fi
  done

  echo "---" >> "$LOG"
  sleep 10
done
SCRIPT

chmod +x /usr/local/bin/lab09-check.sh

systemd-run \
  --unit=lab09-probe \
  --collect \
  /usr/local/bin/lab09-check.sh
```

### What the Script Does

- Runs on EC2 during instance initialization.
- Checks HTTPS connectivity to both endpoints.
- Records connection results.
- Continues independently of the Session Manager terminal.
- Captures before, during, and after remediation evidence.

The script records successful HTTPS responses even if the AWS service returns an authentication-related HTTP status.

A nonzero HTTP status indicates that an HTTP response was received; it does not prove that a Systems Manager API action was authorized.

---

## 12. Launch Private EC2

### Step 1 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not launch duplicate instances.

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$EC2_SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://endpoint-probe.sh \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Confirm Private IP Configuration

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
State: running
PrivateIP: 10.90.1.x
PublicIP: null
```

---

## 13. Establish Healthy Connectivity

### Step 1 — Verify SSM Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration: `Online`.

### Step 2 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Alternatively, use the Session Manager connection in the AWS Console.

### Step 3 — Verify Private DNS

Inside EC2:

```bash
getent ahostsv4 ssm.us-east-1.amazonaws.com
```

```bash
getent ahostsv4 ssmmessages.us-east-1.amazonaws.com
```

Expected: private IP addresses associated with the interface endpoints.

### Step 4 — Verify Endpoint Connectivity Logs

```bash
sudo tail -n 25 /var/tmp/vpc-lab09-probe.log
```

Example of healthy results:

```text
ssm=HTTPS_REACHABLE HTTP_403
ssmmessages=HTTPS_REACHABLE HTTP_403
```

The actual HTTP status may differ.

### Step 5 — Exit

```bash
exit
```

Both endpoint paths should work before introducing the failure.

---

## 14. Reproduce the Endpoint Failure

### Step 1 — Remove the SSM Endpoint Inbound Rule

From WSL2:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SSM_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

This is the intentional fault.

### Step 2 — Verify the Missing Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SSM_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 3 — Verify the Endpoint Remains Available

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,PrivateDNS:PrivateDnsEnabled,Groups:Groups}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
State: available
PrivateDNS: true
```

### Step 4 — Check Systems Manager Status

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Session Manager may stay connected temporarily or show an updated status after a delay.

Existing messaging connections and the healthy `ssmmessages` endpoint can allow some management behavior to continue.

### Expected Failure State

| Component | Status |
|---|---|
| EC2 | Running |
| VPC DNS | Enabled |
| Endpoint private DNS | Enabled |
| SSM endpoint | Available |
| Messages endpoint | Available |
| SSM SG inbound TCP 443 | Missing |
| Messages SG inbound TCP 443 | Allowed |
| New SSM HTTPS connections | Blocked |
| Management functionality | May be degraded |

---

## 15. Troubleshooting Investigation

### Check 1 — Inspect Both Endpoint Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$SSM_SG_ID" "$MSG_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | TCP 443 from EC2 SG |
|---|---|
| SSM endpoint | Missing |
| Messages endpoint | Present |

### Check 2 — Verify Interface Endpoint State

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{Service:ServiceName,State:State,DNS:PrivateDnsEnabled}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: both available with private DNS enabled.

### Check 3 — Inspect Endpoint ENIs

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SSM_SG_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,PrivateIP:PrivateIpAddress,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: private network interface associated with the SSM endpoint SG.

### Check 4 — Verify VPC DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `True` for both.

### Check 5 — Verify VPC Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected: VPC-local route.

### Check 6 — Verify EC2 Egress

```bash
aws ec2 describe-security-groups \
  --group-ids "$EC2_SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound TCP 443 permitted by the initial egress rule.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Running |
| Interface endpoints | Available |
| Private DNS | Enabled |
| VPC DNS | Enabled |
| Routing | Correct |
| EC2 outbound | Allowed |
| Messages endpoint inbound | Allowed |
| SSM endpoint inbound | Missing TCP 443 |
| Root cause | SSM endpoint SG misconfiguration |

---

## 16. Root Cause Analysis

### Root Cause

The security group attached to the SSM interface endpoint did not contain an inbound rule permitting TCP 443 from the EC2 security group.

### Technical Explanation

The EC2 instance attempts to establish an HTTPS connection to the SSM service hostname.

Private DNS resolves the hostname to a private endpoint IP.

The destination endpoint security group must permit the incoming TCP connection.

Without a matching rule, the new connection is blocked before the request reaches the service.

### Root Cause Flow

```text
Private EC2
    |
    v
DNS Lookup
    |
    v
SSM Endpoint Private IP
    |
    v
Endpoint Security Group
    |
    X
No Matching Inbound TCP 443 Rule
    |
    X
Connection Fails
```

### Five Whys

1. **Why did endpoint connectivity fail?** New HTTPS connections were blocked.
2. **Why were connections blocked?** The endpoint SG lacked inbound TCP 443 permission.
3. **Why did the endpoint still show available?** Endpoint resource availability does not guarantee application connectivity.
4. **Why didn't valid DNS solve the problem?** DNS resolution and network authorization are separate operations.
5. **How can the issue be prevented?** Manage endpoint security groups with infrastructure as code, code review, and post-deployment connectivity tests.

---

## 17. Remediation

### Step 1 — Restore the Missing Inbound Rule

From WSL2:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SSM_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify the Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SSM_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: TCP
Port: 443
Source: EC2 Security Group
```

### Step 3 — Verify EC2 Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `Online` after recovery if the connection was interrupted.

### Step 4 — Reconnect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Inspect Probe Results

Inside EC2:

```bash
sudo cat /var/tmp/vpc-lab09-probe.log
```

An illustrative successful experiment:

```text
ssm=HTTPS_REACHABLE HTTP_403
ssmmessages=HTTPS_REACHABLE HTTP_403
---
ssm=CONNECT_FAILED
ssmmessages=HTTPS_REACHABLE HTTP_403
---
ssm=HTTPS_REACHABLE HTTP_403
ssmmessages=HTTPS_REACHABLE HTTP_403
```

The exact HTTP codes and timing may differ.

### Step 6 — Verify DNS Resolution

```bash
getent ahostsv4 ssm.us-east-1.amazonaws.com
getent ahostsv4 ssmmessages.us-east-1.amazonaws.com
```

Expected: private endpoint IPv4 addresses.

### Verification Matrix

| Check | Healthy | Failure | Restored |
|---|---|---|---|
| EC2 | Running | Running | Running |
| SSM endpoint | Available | Available | Available |
| Messaging endpoint | Available | Available | Available |
| Private DNS | Enabled | Enabled | Enabled |
| EC2 outbound | Allowed | Allowed | Allowed |
| SSM SG inbound 443 | Allowed | Missing | Restored |
| Messages SG inbound 443 | Allowed | Allowed | Allowed |
| SSM HTTPS | Working | Failing for new connections | Working |
| Management | Available | May be affected | Available |

---

## 18. Production Best Practices

### Security Group Design

- Use a dedicated security group for each endpoint type when troubleshooting requires separate controls.
- Permit only the ports and sources needed.
- Use security group references rather than broad CIDR ranges when practical.
- Avoid unrestricted inbound access from `0.0.0.0/0`.
- Review endpoint and instance security groups together.

### PrivateLink Troubleshooting

1. Verify endpoint service name.
2. Verify endpoint state.
3. Check subnet placement.
4. Inspect endpoint network interfaces.
5. Verify private DNS.
6. Check VPC DNS attributes.
7. Inspect the EC2 security group outbound rules.
8. Inspect endpoint security group inbound rules.
9. Review relevant network ACLs.
10. Verify endpoint policy and IAM permissions when network connectivity works but API actions fail.
11. Test the connection from the actual workload.
12. Recheck functionality after remediation.

### Production Recommendations

- Manage endpoint configurations with Terraform.
- Use pull requests for networking changes.
- Review endpoint security group changes.
- Monitor application and SSM Agent connectivity.
- Prefer private connectivity for workloads that do not require public internet access.
- Use multiple Availability Zones when service availability requirements justify it.
- Delete unused test endpoints to control costs.

---

## 19. Interview Questions and Answers

### Q1. What is an interface VPC endpoint?

An interface VPC endpoint provides private connectivity to supported AWS services using AWS PrivateLink.

### Q2. Does it require an Internet Gateway?

No. The workload can use the endpoint privately through the VPC network.

### Q3. Why does an interface endpoint use a security group?

To control traffic entering its private endpoint network interfaces.

### Q4. What port is normally required for Systems Manager endpoints?

TCP 443.

### Q5. Why did the endpoint remain available while HTTPS failed?

The endpoint resource was provisioned, but its security group blocked new incoming connections.

### Q6. What is private DNS for an interface endpoint?

It allows the normal service hostname to resolve to the endpoint's private IP addresses.

### Q7. Why are `ssm` and `ssmmessages` endpoints different?

They serve different Systems Manager communication functions. Session Manager uses messaging connectivity, while Systems Manager also uses its service API endpoint.

### Q8. What is the difference between an interface endpoint and an S3 gateway endpoint?

An interface endpoint uses private network interfaces and security groups. An S3 gateway endpoint uses route table entries and an endpoint policy.

### Q9. What is the difference between Lab 08 and Lab 09?

Lab 08 disables VPC DNS support. Lab 09 keeps DNS enabled but blocks HTTPS through the endpoint security group.

### Q10. Why is a security group reference useful?

It limits access to network interfaces associated with the referenced security group instead of allowing an entire subnet or public address range.

### Q11. Can IAM permissions cause endpoint access problems?

Yes. Network connectivity may work while an API request is denied by IAM or an endpoint policy.

### Q12. How would you explain this lab in an interview?

> I created a private AWS VPC without internet or NAT gateway access. I deployed a private EC2 instance and interface VPC endpoints for Systems Manager. After verifying connectivity, I intentionally removed inbound TCP 443 permission from the SSM endpoint's security group. The endpoint remained available and DNS continued working, but new HTTPS connections failed. I investigated endpoint state, security groups, DNS, and routing. After identifying the missing rule, I restored HTTPS access from the EC2 security group and verified connectivity recovered.

---

## 20. Cleanup

**Important:** Interface endpoints are billable resources. Verify that all resources belong exclusively to `VPC-Troubleshooting-Lab09` before deleting anything.

### Step 1 — Verify Resource Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Service:ServiceName,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination`.

### Step 3 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Both Interface Endpoints

```bash
aws ec2 delete-vpc-endpoints \
  --vpc-endpoint-ids "$SSM_ENDPOINT_ID" "$MSG_ENDPOINT_ID" \
  --region "$AWS_REGION"
```

Verify their deletion:

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm that both endpoint ENIs have been removed before proceeding.

### Step 5 — Check Remaining Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no remaining lab network interfaces.

### Step 6 — Revoke Endpoint Security Group Rules

For the SSM endpoint:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SSM_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

For the messaging endpoint:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$MSG_SG_ID" \
  --protocol tcp \
  --port 443 \
  --source-group "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

If a rule is already absent, skip its revoke command.

### Step 7 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$SSM_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$MSG_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Confirm the profile is not used by another workload.

### Step 9 — Delete IAM Resources

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 10 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Verify VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Confirm no remaining workloads or endpoints depend on the VPC.

### Step 12 — Delete Dedicated VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Verify Final Cleanup

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Check the root EBS volume:

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

`InvalidVolume.NotFound` indicates the volume is deleted.

Also verify both interface endpoints are gone.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| SSM endpoint | Deleted |
| Messages endpoint | Deleted |
| Endpoint ENIs | Removed |
| EC2 security group | Deleted |
| SSM endpoint SG | Deleted |
| Messages endpoint SG | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Private subnet | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
09-vpc-endpoint-connectivity-failure/
├── README.md
├── ec2-trust-policy.json
└── endpoint-probe.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation |
| `ec2-trust-policy.json` | Allows EC2 to assume the SSM role |
| `endpoint-probe.sh` | Creates a background endpoint connectivity monitor |

Do not commit AWS credentials, private keys, or sensitive account information.

---

## 22. Lessons Learned

This lab demonstrates that an interface endpoint can be available even when applications cannot establish HTTPS connections to it.

The endpoint state, subnet placement, and private DNS configuration were correct.

The connectivity failure was caused by a missing inbound TCP 443 rule on the endpoint's security group.

The investigation showed why it is important to inspect security groups attached to endpoint network interfaces instead of focusing only on the EC2 security group.

It also demonstrated how private AWS service connectivity can work without an Internet Gateway or NAT Gateway.

**Key Lesson:** When troubleshooting an interface VPC endpoint, verify its endpoint security group, private DNS, network interfaces, and actual HTTPS connectivity. An endpoint showing `available` does not guarantee the service is reachable.

---

## 23. Skills Demonstrated

- AWS PrivateLink
- Interface VPC endpoints
- Private subnet architecture
- VPC endpoint security groups
- AWS Systems Manager connectivity
- Private DNS resolution
- EC2 network troubleshooting
- AWS CLI v2
- Linux HTTPS diagnostics
- Least-privilege network access
- Background connectivity monitoring
- Root cause analysis
- Incident remediation
- Cost-aware AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-009 |
| Problem | Interface endpoint HTTPS connectivity failure |
| Root Cause | Missing endpoint inbound TCP 443 rule |
| Endpoint State | Available |
| Private DNS | Enabled |
| Internet Gateway | Not required |
| NAT Gateway | Not required |
| Remediation | Restore TCP 443 from EC2 SG |
| HTTPS After Fix | Successful |
| Systems Manager | Available |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Interface VPC endpoints enable private access to AWS services, but their security groups must explicitly allow incoming application connections. Correct DNS and endpoint availability alone are not enough.
