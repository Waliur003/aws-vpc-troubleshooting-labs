# Lab 08 — VPC DNS Resolution Disabled

## Overview

This lab demonstrates how to troubleshoot an AWS VPC DNS resolution failure caused by disabling the `enableDnsSupport` attribute.

An Amazon EC2 instance is deployed in a public subnet with working internet access. Initially, the instance can resolve domain names and connect to external services using HTTPS.

We intentionally disable VPC DNS support, investigate why hostname resolution stops working, and restore the correct configuration.

The main objective is to understand the difference between **DNS resolution problems and internet routing problems**.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce DNS Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-008 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, dig, Linux networking tools |
| VPC CIDR | `10.80.0.0/16` |
| Public Subnet | `10.80.1.0/24` |
| Internet Gateway | Attached |
| Default Route | `0.0.0.0/0 → IGW` |
| DNS Resolver | AmazonProvidedDNS |
| VPC Resolver IP | `169.254.169.253` or `10.80.0.2` |
| Simulated Failure | `enableDnsSupport=false` |
| Root Cause | VPC DNS support disabled |
| Remediation | Re-enable DNS support |
| Verification | DNS lookup and HTTPS connectivity |
| Management | AWS Systems Manager Session Manager |

---

## 1. Production Incident Scenario

### Incident Description

A company hosts an application on an EC2 instance inside an AWS VPC.

The application communicates with external services using domain names such as `example.com`.

After a network configuration change, the application begins reporting DNS resolution failures.

The EC2 instance remains running. The internet gateway is attached, the subnet has the correct route table, and outbound traffic is permitted.

However, the VPC's DNS support attribute has been disabled.

### Symptoms

- Domain names cannot be resolved through AmazonProvidedDNS.
- Applications cannot connect to services that require new DNS lookups.
- HTTP requests using hostnames may fail.
- The EC2 instance can remain healthy.
- IP connectivity may still work.
- Systems Manager may lose connectivity if it cannot resolve AWS endpoints.

### Business Impact

- External API calls fail.
- Software updates may stop working.
- Applications cannot discover DNS-based endpoints.
- Service integrations become unavailable.
- Monitoring and management agents may disconnect.
- Production troubleshooting time increases.

### Investigation Objective

Identify whether the failure is caused by DNS resolution, VPC routing, security groups, or an internet gateway problem, then restore DNS functionality.

---

## 2. AWS Architecture

### Healthy Architecture

```text
                      Internet
                         |
                  Internet Gateway
                         |
           +----------------------------+
           | AWS VPC                    |
           | 10.80.0.0/16               |
           |                            |
           | DNS Support: Enabled       |
           | DNS Hostnames: Enabled     |
           |                            |
           | AmazonProvidedDNS          |
           | 169.254.169.253            |
           | 10.80.0.2                  |
           |                            |
           | Public Subnet              |
           | 10.80.1.0/24               |
           |                            |
           | Route: 0.0.0.0/0 → IGW      |
           |                            |
           | EC2 Instance               |
           | Private + Public IPv4      |
           +----------------------------+
```

### Broken Architecture

```text
                   EC2 Instance
                        |
                        v
               DNS Query: example.com
                        |
                        v
                 AmazonProvidedDNS
                        |
                        X
              DNS Support Disabled
                        |
                        X
              DNS Resolution Failed
```

### Important Distinction

```text
DNS Resolution:
Domain Name → IP Address

Internet Routing:
IP Address → Destination Network
```

DNS resolution and IP routing are separate functions.

A VPC can have working internet routing but fail to resolve hostnames.

---

## 3. Understanding VPC DNS Attributes

AWS provides two important DNS attributes.

### enableDnsSupport

Controls whether DNS resolution through the Amazon-provided DNS resolver is supported in the VPC.

When disabled, DNS queries to the Amazon-provided resolver do not work normally.

### enableDnsHostnames

Controls DNS hostname-related behavior, including public DNS hostname assignment to eligible EC2 instances.

### Comparison

| Attribute | Enabled | Disabled |
|---|---|---|
| `enableDnsSupport` | Amazon-provided DNS resolution supported | Amazon-provided DNS resolution unavailable |
| `enableDnsHostnames` | Eligible EC2 DNS hostnames supported | Corresponding hostname behavior disabled |

### AmazonProvidedDNS

AWS provides DNS resolution using addresses such as:

```text
169.254.169.253
10.80.0.2
```

The second address is calculated using the VPC IPv4 CIDR base address plus two.

For this lab:

```text
VPC CIDR: 10.80.0.0/16
VPC DNS:  10.80.0.2
```

### Important Note

Disabling `enableDnsSupport` does not necessarily prevent all possible DNS lookups.

An application using an independent reachable DNS resolver or cached records may continue to resolve some names.

This lab specifically investigates the Amazon-provided VPC DNS resolver.

---

## 4. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC permissions
- IAM role management permissions
- AWS Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated test VPC.
- Do not disable DNS in shared production VPCs.
- Keep inbound SSH closed.
- Verify AWS account identity before making changes.
- Record baseline connectivity before fault injection.
- Perform recovery through the local AWS CLI.
- Remove temporary resources after the lab.

### Cost Considerations

The lab may incur EC2 compute, EBS, public IPv4, and data transfer charges.

No NAT gateway is required.

---

## 5. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab08"

export VPC_NAME="cloud-lab08-vpc"
export SUBNET_NAME="cloud-lab08-public-subnet"
export IGW_NAME="cloud-lab08-igw"
export RT_NAME="cloud-lab08-public-rt"
export SG_NAME="cloud-lab08-sg"
export INSTANCE_NAME="cloud-lab08-ec2"

export ROLE_NAME="cloud-lab08-ssm-role"
export PROFILE_NAME="cloud-lab08-ssm-profile"

export VPC_CIDR="10.80.0.0/16"
export SUBNET_CIDR="10.80.1.0/24"
```

Verify:

```bash
aws sts get-caller-identity
aws --version
```

### Step 2 — Select Availability Zone

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose a supported availability zone:

```bash
export LAB_AZ="us-east-1a"
```

### Step 3 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Avoid creating duplicate lab resources.

---

## 6. Create the VPC

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

### Step 4 — Verify Both Attributes

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

Expected:

```text
True
True
```

---

## 7. Create the Public Subnet

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

Enable public IPv4 assignment:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

---

## 8. Create the Internet Gateway and Route Table

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

Attach:

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Add Default Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Associate the Subnet

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify routes:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.80.0.0/16 → local
0.0.0.0/0    → IGW
```

---

## 9. Configure Security Group and IAM

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab08 VPC DNS troubleshooting" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Keep inbound rules empty. Confirm the default outbound allow rule exists.

### Step 2 — Create EC2 Trust Policy

Save as `ec2-trust-policy.json`:

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

### Step 3 — Create IAM Role

Verify that the role and profile names are not already in use.

```bash
aws iam get-role --role-name "$ROLE_NAME"
aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME"
```

For unused names, `NoSuchEntity` is expected.

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 4 — Attach SSM Policy

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

## 10. Launch Amazon Linux EC2

### Step 1 — Retrieve AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Lab Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
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

### Step 5 — Verify EC2 IP Addressing

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: EC2 running with private and public IPv4 addresses.

---

## 11. Establish Healthy DNS Connectivity

### Step 1 — Connect Using Session Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Alternatively, use the AWS Console.

### Step 2 — Inspect DNS Configuration

Inside EC2:

```bash
cat /etc/resolv.conf
getent ahostsv4 example.com
ip route
```

### Step 3 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: HTTP response.

### Step 4 — Test AmazonProvidedDNS

Install DNS tools if necessary:

```bash
sudo dnf install -y bind-utils
```

Query:

```bash
dig @169.254.169.253 example.com A +time=2 +tries=1
```

Test the VPC CIDR-plus-two address:

```bash
dig @10.80.0.2 example.com A +time=2 +tries=1
```

Expected: valid DNS answers.

---

## 12. Prepare Connectivity Monitoring

Disabling DNS may interrupt Session Manager access, so create a background recorder before introducing the failure.

### Step 1 — Capture Working IP

Inside EC2:

```bash
export TEST_IP=$(getent ahostsv4 example.com \
  | awk 'NR==1 {print $1}')

echo "$TEST_IP"
```

Confirm this returns an actual IPv4 address.

### Step 2 — Test Without a New DNS Lookup

```bash
curl -4 -I \
  --resolve "example.com:443:$TEST_IP" \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

The `--resolve` option supplies a known destination IP while preserving the hostname needed for HTTPS.

Verify this works before proceeding.

### Step 3 — Create Monitoring Script

Inside EC2:

```bash
sudo tee /usr/local/bin/vpc-lab08-probe.sh > /dev/null <<'EOF'
#!/bin/bash

TEST_IP="$1"
LOG="/var/tmp/vpc-lab08-probe.log"

for i in $(seq 1 72); do
  echo "Time: $(date -u +%FT%TZ)" >> "$LOG"

  if timeout 6 getent ahostsv4 example.com \
      > /dev/null 2>&1; then
    echo "DNS_RESULT=OK" >> "$LOG"
  else
    echo "DNS_RESULT=FAILED" >> "$LOG"
  fi

  if curl -4 -fsS \
      --connect-timeout 2 \
      --max-time 5 \
      https://example.com/ \
      -o /dev/null; then
    echo "NORMAL_HTTPS=OK" >> "$LOG"
  else
    echo "NORMAL_HTTPS=FAILED" >> "$LOG"
  fi

  if curl -4 -fsS \
      --resolve "example.com:443:$TEST_IP" \
      --connect-timeout 2 \
      --max-time 5 \
      https://example.com/ \
      -o /dev/null; then
    echo "DIRECT_IP_HTTPS=OK" >> "$LOG"
  else
    echo "DIRECT_IP_HTTPS=FAILED" >> "$LOG"
  fi

  echo "---" >> "$LOG"
  sleep 10
done
EOF
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/vpc-lab08-probe.sh
```

Start recorder:

```bash
sudo systemd-run \
  --unit=vpc-lab08-probe \
  --collect \
  /usr/local/bin/vpc-lab08-probe.sh "$TEST_IP"
```

Check:

```bash
sudo tail -n 15 /var/tmp/vpc-lab08-probe.log
```

Expected baseline:

```text
DNS_RESULT=OK
NORMAL_HTTPS=OK
DIRECT_IP_HTTPS=OK
```

Exit Session Manager:

```bash
exit
```

---

## 13. Reproduce the DNS Failure

### Step 1 — Verify DNS Support Is Enabled

From WSL2:

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `True`.

### Step 2 — Disable DNS Support

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --no-enable-dns-support \
  --region "$AWS_REGION"
```

This is the intentional misconfiguration.

### Step 3 — Confirm the Attribute

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
False
```

### Step 4 — Verify Routing Remains Correct

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.80.0.0/16 → local
0.0.0.0/0    → Internet Gateway
```

### Step 5 — Verify the Internet Gateway

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: IGW remains attached.

### Step 6 — Check EC2 and SSM

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

SSM may disconnect because AWS service hostname resolution is no longer working.

### Expected Failure

| Test | Expected Finding |
|---|---|
| VPC DNS support | Disabled |
| EC2 status | Running |
| Internet gateway | Attached |
| Route table | Correct |
| AmazonProvidedDNS | Not resolving |
| Hostname HTTPS | May fail |
| IP-pinned HTTPS | Can still work |
| Session Manager | May disconnect |

DNS caching may temporarily hide the failure. Do not assume every application will fail instantly.

---

## 14. Troubleshooting Investigation

### Check 1 — VPC DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

Finding: `False`.

### Check 2 — DNS Hostname Attribute

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text \
  --region "$AWS_REGION"
```

Finding: `True`.

### Check 3 — Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Finding: correct internet route.

### Check 4 — Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: outbound traffic allowed.

### Check 5 — Network ACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkAcls[].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Finding: default NACL configuration unchanged.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Running |
| Public IPv4 | Assigned |
| IGW | Attached |
| Route table | Correct |
| Security group | Outbound allowed |
| Network ACL | Unchanged |
| DNS hostnames | Enabled |
| DNS support | Disabled |
| Root cause | `enableDnsSupport=false` |

---

## 15. Root Cause Analysis

### Root Cause

The VPC's DNS support attribute was disabled, preventing normal DNS resolution through AmazonProvidedDNS.

### Technical Explanation

Applications typically resolve hostnames to IP addresses before establishing network connections.

When the Amazon-provided resolver is unavailable, applications depending on it cannot obtain destination addresses.

This affects DNS resolution even though the internet gateway, route table, and IP networking may still function.

### Root Cause Flow

```text
Application
     |
     v
DNS Lookup
     |
     v
AmazonProvidedDNS
     |
     v
enableDnsSupport = false
     |
     X
DNS Resolution Failed
     |
     X
Hostname-Based Connection Fails
```

### Five Whys

1. **Why did hostname-based HTTPS fail?** The application could not resolve the hostname.
2. **Why did resolution fail?** AmazonProvidedDNS support was disabled.
3. **Why was routing unaffected?** DNS and packet routing are separate services.
4. **Why could IP-based HTTPS work?** The request can avoid a fresh DNS lookup.
5. **How can the incident be prevented?** Manage VPC DNS attributes using reviewed infrastructure as code and validate DNS after configuration changes.

---

## 16. Remediation

### Step 1 — Re-enable DNS Support

From WSL2:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"
```

### Step 2 — Verify DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
True
```

### Step 3 — Verify DNS Hostnames

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `True`.

### Step 4 — Verify Systems Manager Recovery

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after reconnection: `Online`.

### Step 5 — Inspect Monitoring Logs

Reconnect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo cat /var/tmp/vpc-lab08-probe.log
```

An illustrative successful experiment could show:

```text
DNS_RESULT=OK
NORMAL_HTTPS=OK
DIRECT_IP_HTTPS=OK
---
DNS_RESULT=FAILED
NORMAL_HTTPS=FAILED
DIRECT_IP_HTTPS=OK
---
DNS_RESULT=OK
NORMAL_HTTPS=OK
DIRECT_IP_HTTPS=OK
```

Use actual captured results as evidence. DNS caches and network conditions can affect the observed sequence.

### Step 6 — Verify DNS

```bash
dig @169.254.169.253 example.com A +time=2 +tries=1
```

```bash
getent ahostsv4 example.com
```

Expected: successful DNS resolution.

### Step 7 — Verify HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

Exit:

```bash
exit
```

---

## 17. Verification Matrix

| Check | Baseline | Failure | After Fix |
|---|---|---|---|
| EC2 running | Yes | Yes | Yes |
| IGW attached | Yes | Yes | Yes |
| Route table | Correct | Correct | Correct |
| DNS support | Enabled | Disabled | Enabled |
| DNS hostnames | Enabled | Enabled | Enabled |
| AmazonProvidedDNS | Working | Unavailable | Working |
| New DNS queries | Successful | Failed | Successful |
| Normal HTTPS | Working | May fail | Working |
| IP-pinned HTTPS | Working | Can remain working | Working |
| SSM | Online | May disconnect | Online |

### Success Criteria

The lab is successful when:

- The VPC's DNS support is enabled.
- AmazonProvidedDNS responds successfully.
- Hostname resolution works.
- HTTPS requests using domain names succeed.
- Routing and internet gateway configuration remain unchanged.
- Systems Manager connectivity is restored.
- Temporary resources are cleaned up.

---

## 18. Production Best Practices

### DNS Troubleshooting Checklist

1. Verify EC2 status.
2. Inspect `/etc/resolv.conf`.
3. Test hostname resolution using `getent` or `dig`.
4. Inspect VPC `enableDnsSupport`.
5. Inspect VPC `enableDnsHostnames`.
6. Verify the configured DNS resolver.
7. Check the effective route table.
8. Confirm internet gateway attachment if internet access is required.
9. Inspect outbound security group rules.
10. Compare DNS-based and IP-pinned connectivity.
11. Restore the correct DNS configuration.
12. Verify application connectivity after remediation.

### Prevention

- Manage VPC DNS settings using Terraform or CloudFormation.
- Review DNS-related configuration changes.
- Keep resource tags consistent.
- Monitor DNS resolution failures.
- Use application-level health checks.
- Document whether workloads use AmazonProvidedDNS or custom DNS servers.
- Avoid changing DNS settings in shared VPCs without impact analysis.

### DNS vs. Routing Troubleshooting

| Symptom | Possible Cause |
|---|---|
| Domain name lookup fails | DNS resolver or configuration problem |
| DNS works but HTTPS times out | Routing, security, endpoint, or service problem |
| IP-pinned HTTPS works but normal HTTPS fails | DNS-related failure likely |
| Both DNS and direct IP connection fail | Broader networking problem possible |
| SSM disconnects after DNS change | AWS endpoint hostname resolution may be affected |

---

## 19. Interview Questions and Answers

### Q1. What is VPC DNS support?

It controls whether the Amazon-provided DNS resolver is supported inside the VPC.

### Q2. What is `enableDnsHostnames`?

It is a separate attribute controlling relevant DNS hostname assignment behavior in the VPC.

### Q3. What DNS IP does AWS provide?

`169.254.169.253`, and the VPC's primary IPv4 CIDR base address plus two.

### Q4. What is the DNS resolver address for `10.80.0.0/16`?

`10.80.0.2`.

### Q5. Can internet routing work when DNS fails?

Yes. DNS resolution and IP packet routing are separate.

### Q6. Why can HTTPS using a hostname fail while an IP-pinned request succeeds?

The hostname request requires DNS resolution, while the IP-pinned request uses a known destination IP.

### Q7. Does disabling VPC DNS support disable every possible DNS resolver?

No. Other reachable DNS services and cached records may still work.

### Q8. Why might Session Manager disconnect?

The SSM Agent depends on connectivity to AWS service endpoints and may be affected when those hostnames cannot be resolved.

### Q9. How do you check DNS support using AWS CLI?

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

### Q10. How do you re-enable DNS support?

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"
```

### Q11. Does a healthy EC2 status check confirm DNS is working?

No. EC2 health checks do not guarantee successful DNS resolution.

### Q12. How would you explain this lab in an interview?

> I created an isolated AWS VPC with a public EC2 instance and verified that DNS resolution and HTTPS access were working. I then intentionally disabled the VPC's DNS support attribute. I used a background monitoring script to compare hostname-based HTTPS requests with requests using a previously resolved IP. I found that the VPC route table, internet gateway, and security group remained correctly configured, but the Amazon-provided DNS resolver was unavailable. I restored DNS support and verified that domain name resolution and HTTPS connectivity worked again.

---

## 20. Cleanup

**Warning:** Verify all resources belong exclusively to Lab 08 before deleting them.

### Step 1 — Verify AWS Account and Tags

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `Project=VPC-Troubleshooting-Lab08`.

### Step 2 — Record EBS Root Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination` before terminating the instance.

### Step 3 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete IAM Resources

Verify ownership:

```bash
aws iam list-role-tags --role-name "$ROLE_NAME"
```

Confirm the role and instance profile are not being used elsewhere.

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

### Step 5 — Delete Security Group

Verify there are no dependent network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

When none remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Remove Route Table Association

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Verify Remaining VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Confirm no remaining resources depend on the VPC.

### Step 11 — Delete Dedicated VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Final Verification

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

Verify the root EBS volume was also removed:

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

An `InvalidVolume.NotFound` response indicates the volume is gone.

### Cleanup Summary

| Resource | Expected Outcome |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Removed |
| Security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Custom route table | Deleted |
| Public subnet | Deleted |
| Internet gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
08-vpc-dns-resolution-disabled/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Infrastructure setup, DNS failure simulation, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | IAM trust policy allowing EC2 to assume the Systems Manager role |

The connectivity monitoring script is created inside the temporary EC2 instance during the hands-on exercise.

Do not commit AWS credentials, access keys, or sensitive account information.

---

## 22. Lessons Learned

This lab demonstrates how applications can lose access to domain-name-based services even when their VPC internet routing remains correct.

The problem was not the internet gateway, security group, or route table.

The root cause was the disabled VPC DNS support attribute.

By comparing hostname resolution with IP-pinned HTTPS connectivity, we can distinguish DNS failures from general network connectivity problems.

The exercise also demonstrates why DNS configuration needs to be included in infrastructure monitoring, change reviews, and troubleshooting procedures.

**Key Lesson:** When AWS applications cannot reach external services by hostname, verify VPC DNS settings before assuming routing or security group problems.

---

## 23. Skills Demonstrated

- AWS VPC DNS troubleshooting
- AmazonProvidedDNS configuration
- `enableDnsSupport` and `enableDnsHostnames`
- DNS resolution diagnostics
- Linux `getent` and `dig`
- HTTPS troubleshooting with `curl`
- DNS versus IP routing analysis
- AWS CLI v2
- EC2 and VPC configuration
- Systems Manager administration
- Background connectivity monitoring
- Root cause analysis
- Controlled fault injection
- Incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-008 |
| Problem | DNS resolution failure |
| Root Cause | VPC DNS support disabled |
| Fault | `enableDnsSupport=false` |
| Remediation | Re-enable DNS support |
| Internet Gateway | Remains attached |
| Route Table | Remains correct |
| DNS After Fix | Successful |
| HTTPS After Fix | Successful |
| SSM After Fix | Online |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** DNS resolution and IP routing are different functions. Correct routing does not guarantee hostname resolution. Always inspect the VPC DNS attributes and test DNS directly when troubleshooting application connectivity problems.
