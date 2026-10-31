# Lab 01 — Public Subnet Cannot Access Internet

## Overview

This lab demonstrates how to troubleshoot an Amazon EC2 instance that cannot access the internet because its public subnet has an incorrect route table configuration.

An EC2 instance can have a public IPv4 address, an attached internet gateway, and permissive outbound security group rules but still lack internet connectivity when its subnet's route table does not contain the required default route.

In this hands-on exercise, we create an isolated Amazon VPC, configure a working public subnet, intentionally remove its internet route, investigate the resulting failure, restore routing, and verify connectivity.

We use AWS Systems Manager Session Manager for secure administration without opening inbound SSH port 22.

**Troubleshooting workflow:**

Provision → Establish Baseline → Simulate Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-001 |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Difficulty | Beginner–Intermediate |
| Region | `us-east-1` |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Linux networking commands |
| VPC CIDR | `10.10.0.0/16` |
| Subnet CIDR | `10.10.1.0/24` |
| Simulated Failure | Missing default internet route |
| Root Cause | No `0.0.0.0/0` route to internet gateway |
| Remediation | Restore route to attached IGW |
| Secure Access | AWS Session Manager |
| Expected Outcome | Internet connectivity restored |

---

## 1. Production Incident Scenario

A company deploys an EC2 instance in a public subnet to run an application that needs to communicate with external services.

The instance is running and has a public IPv4 address.

However, outgoing HTTPS requests fail.

Initial checks show that:

- The internet gateway exists and is attached to the VPC.
- The EC2 security group permits outbound traffic.
- A public IPv4 address is associated with the instance.
- The instance's subnet route table is missing the default internet route.

The cloud engineer must identify the incorrect route table configuration and restore outbound connectivity.

### Expected Behavior

The EC2 instance should successfully run:

```bash
curl -4 -I https://example.com
```

Expected: an HTTP response indicating that the remote service is reachable.

### Simulated Failure

The subnet route table has only its VPC-local route:

```text
Destination      Target
10.10.0.0/16     local
```

It is missing:

```text
Destination      Target
0.0.0.0/0        igw-xxxxxxxx
```

Traffic destined outside the VPC has no matching internet route.

### Potential Business Impact

- Failed external API requests
- Interrupted application integrations
- Failed software package downloads
- Deployment and initialization failures
- Inability to access public AWS service endpoints
- Loss of Systems Manager connectivity when it depends on the internet path
- Increased incident response time

---

## 2. AWS Architecture

### Healthy Network

```text
                   Internet
                      |
                      |
               Internet Gateway
                  igw-xxxx
                      |
                      |
             +------------------+
             |     AWS VPC      |
             |   10.10.0.0/16   |
             |                  |
             |  Public Subnet   |
             |  10.10.1.0/24    |
             |                  |
             |  +------------+  |
             |  | Amazon EC2 |  |
             |  | Public IP  |  |
             |  | SSM Agent  |  |
             |  +------------+  |
             |                  |
             |  Route Table     |
             |  10.10.0.0/16    |
             |      → local     |
             |  0.0.0.0/0       |
             |      → IGW       |
             +------------------+
```

### Broken Network

```text
                   Internet
                      |
               Internet Gateway
                      |
                      X
              Missing Default Route
                      |
             +------------------+
             |     AWS VPC      |
             |                  |
             |  Public Subnet   |
             |                  |
             |     Amazon EC2   |
             |                  |
             |  Route Table:    |
             |  10.10.0.0/16    |
             |      → local     |
             |                  |
             |  No 0.0.0.0/0    |
             +------------------+
```

### Corrected Route

```text
0.0.0.0/0 → Internet Gateway → Internet
```

**Important:** The Linux instance's default gateway and the AWS VPC route table are different layers of routing. In this lab, we intentionally change the VPC route table, not the guest operating system's route.

---

## 3. Understanding Public Subnet Internet Access

An IPv4 public subnet is a subnet whose associated route table has a default route to an attached internet gateway.

For an EC2 instance to communicate with the public internet, the following must be configured appropriately:

| Component | Requirement |
|---|---|
| Internet gateway | Attached to the correct VPC |
| Route table | Default route to the IGW |
| Subnet association | Uses the intended route table |
| EC2 public IPv4 | Assigned to the instance |
| Security group | Permits the outbound traffic |
| Network ACL | Permits traffic in both directions |
| DNS | Resolves domain names if hostnames are used |
| Linux networking | Has a valid network interface and default route |

A public IPv4 address alone does not make an instance internet-accessible.

An internet gateway attachment alone is also insufficient without the correct subnet routing.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Permissions to manage temporary VPC and EC2 resources
- IAM role management permissions
- Systems Manager access
- Git and GitHub

### Safety Precautions

- Create a dedicated VPC for the lab.
- Do not modify the default VPC.
- Do not open inbound SSH access.
- Use an IAM role with SSM permissions.
- Expect Session Manager to disconnect when the internet route is removed.
- Restore the route from the local WSL2 terminal.
- Verify ownership before deleting any resource.
- Remove temporary resources after completing the exercise.

### AWS Costs

The lab can incur EC2, EBS, public IPv4, and data-transfer charges. No NAT gateway or paid interface endpoint is required.

---

## 5. Prepare the Environment

Run these commands from Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab01"

export VPC_NAME="cloud-lab01-vpc"
export SUBNET_NAME="cloud-lab01-public-subnet"
export IGW_NAME="cloud-lab01-igw"
export RT_NAME="cloud-lab01-public-rt"
export SG_NAME="cloud-lab01-sg"
export INSTANCE_NAME="cloud-lab01-ec2"

export ROLE_NAME="cloud-lab01-ssm-role"
export PROFILE_NAME="cloud-lab01-ssm-profile"

export VPC_CIDR="10.10.0.0/16"
export SUBNET_CIDR="10.10.1.0/24"
```

Verify the AWS identity:

```bash
aws sts get-caller-identity
```

### Step 2 — Choose an Availability Zone

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose a compatible AZ:

```bash
export LAB_AZ="us-east-1a"
```

Replace the AZ if necessary.

---

## 6. Create the Dedicated VPC

### Step 1 — Check for Existing Lab VPC

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate if an existing lab VPC is found.

### Step 2 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$VPC_ID"
```

### Step 3 — Enable DNS Support

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"
```

### Step 4 — Enable DNS Hostnames

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

These modifications apply only to the dedicated lab VPC.

---

## 7. Create the Public Subnet

### Step 1 — Create Subnet

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

### Step 2 — Enable Public IPv4 Assignment

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 3 — Verify

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `PublicIP` is `True`.

---

## 8. Create and Attach Internet Gateway

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Attach to VPC

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Verify

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: gateway attached to the lab VPC.

---

## 9. Configure the Public Route Table

### Step 1 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Add Default Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Associate Route Table With Subnet

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Verify

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[].{Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
10.10.0.0/16 → local
0.0.0.0/0  → Internet Gateway
```

---

## 10. Create EC2 Security Group

### Step 1 — Check Existing Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

### Step 2 — Create Security Group

If unused:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "VPC Lab01 public subnet troubleshooting" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Traffic Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

- Inbound rules: empty.
- Outbound rules: allow traffic under the group's default egress configuration.

No inbound SSH rule is necessary.

---

## 11. Configure IAM Role for Session Manager

### Step 1 — Create Trust Policy

File: `ec2-trust-policy.json`

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

Create the file locally:

```bash
cat > ec2-trust-policy.json <<'EOF'
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
EOF
```

### Step 2 — Create Role

First verify the role name is unused:

```bash
aws iam get-role --role-name "$ROLE_NAME"
```

For a new role, `NoSuchEntity` is expected.

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach Systems Manager Policy

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 4 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 5 — Add Role to Profile

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 6 — Verify

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output table
```

Allow for IAM propagation before launching EC2.

---

## 12. Launch Amazon Linux 2023

### Step 1 — Retrieve AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate.

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

### Step 5 — Verify Addresses and State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,Subnet:SubnetId,VPC:VpcId}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: running instance, private IP, public IPv4, and intended VPC/subnet.

---

## 13. Establish Working Connectivity

### Step 1 — Check Systems Manager Registration

From WSL2:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration:

```text
Online
```

### Step 2 — Connect With Session Manager

From AWS Console:

EC2 → Instances → Select instance → Connect → Session Manager → Connect

Or from AWS CLI, if the local Session Manager plugin is installed:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Linux Network

Inside EC2:

```bash
ip -br addr
ip route
```

Expected: network interface is up and a valid Linux default route exists.

### Step 4 — Verify DNS

```bash
getent ahostsv4 example.com
```

Expected: IPv4 addresses returned.

### Step 5 — Verify HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

### Step 6 — Optional Direct IP Connectivity

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://1.1.1.1
```

A response supports basic IP connectivity. A failure by itself is not conclusive because the endpoint and TLS handling can also affect the result.

Exit:

```bash
exit
```

### Healthy Baseline Summary

| Component | Expected State |
|---|---|
| EC2 | Running |
| EC2 status checks | OK |
| Public IPv4 | Assigned |
| Internet gateway | Attached |
| Default internet route | Present |
| Security group egress | Allowed |
| DNS | Working |
| HTTPS | Working |
| Systems Manager | Online |

---

## 14. Reproduce Public Subnet Internet Failure

**Important:** Removing the subnet's default route may disconnect Session Manager. Use the WSL2 AWS CLI for fault injection and recovery.

### Step 1 — Record the Existing Route Table

From WSL2:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Confirm that the default route targets the Lab 01 internet gateway.

Also verify the route table is associated only with the intended lab subnet.

### Step 2 — Remove the Default Route

```bash
aws ec2 delete-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 3 — Verify the Failure Configuration

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Destination      Target
10.10.0.0/16     local
```

The default internet route is now absent.

### Step 4 — Inspect Instance Status

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

The EC2 status checks may remain healthy.

### Step 5 — Inspect Systems Manager Status

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected possible symptom: eventual `ConnectionLost`.

Systems Manager reports may lag, so the instance can temporarily remain listed as `Online`.

The missing route is the direct configuration evidence of the simulated failure.

---

## 15. Troubleshooting Investigation

### Check 1 — Verify Internet Gateway

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the IGW remains attached to the lab VPC.

### Check 2 — Verify Public IPv4

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: public IPv4 still assigned.

### Check 3 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound traffic permitted.

### Check 4 — Inspect Network ACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the new VPC's default network ACL continues to allow traffic, since we have not modified it.

### Check 5 — Inspect Effective Route Table

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

- The subnet is associated with the dedicated route table.
- The VPC-local route is present.
- The `0.0.0.0/0` route is missing.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 state | Running |
| Public IPv4 | Present |
| Internet gateway | Attached |
| Security group egress | Allowed |
| Network ACL | Default allow rules |
| Route table association | Correct |
| Default internet route | Missing |
| Root cause | Incorrect route table configuration |

---

## 16. Root Cause Analysis

### Root Cause

The public subnet's custom route table no longer contained a default IPv4 route to the internet gateway.

### Technical Explanation

The route table determines the next-hop target for traffic leaving the subnet.

The local route handles traffic within the VPC.

Internet-bound traffic requires a matching route such as:

```text
0.0.0.0/0 → Internet Gateway
```

When that route is removed, the instance cannot use the internet gateway for normal IPv4 internet communication.

The existence of a public IPv4 address and an attached IGW does not compensate for the missing route.

### Root Cause Flow

```text
EC2 Outbound HTTPS Request
             |
             v
      VPC Route Table
             |
             v
      Destination: Internet
             |
             v
     No Matching Default Route
             |
             X
     Internet Access Fails
```

### Five Whys

1. **Why couldn't EC2 access the internet?** Its subnet had no internet route.
2. **Why was internet traffic not routed correctly?** The default route was removed.
3. **Why didn't the attached IGW solve it?** An attached gateway must also be referenced by the applicable route table.
4. **Why did the EC2 instance still appear healthy?** EC2 status checks do not guarantee public internet connectivity.
5. **How can recurrence be prevented?** Validate subnet routes and manage VPC networking changes through reviewed infrastructure configuration.

---

## 17. Remediate the Failure

### Step 1 — Restore the Default Route

From WSL2:

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify the Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.10.0.0/16 → local
0.0.0.0/0  → igw-xxxxxxxx
```

### Step 3 — Verify Systems Manager Recovery

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after agent reconnection: `Online`.

### Step 4 — Reconnect to EC2

Use Session Manager through the Console or AWS CLI.

### Step 5 — Test DNS

Inside EC2:

```bash
getent ahostsv4 example.com
```

Expected: valid IPv4 answers.

### Step 6 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: an HTTP response showing successful access.

### Step 7 — Inspect Linux Route

```bash
ip route
```

The Linux default gateway may remain unchanged because our fault was at the AWS VPC routing layer.

Exit:

```bash
exit
```

---

## 18. Recovery Verification

| Component | Healthy Baseline | During Failure | After Fix |
|---|---|---|---|
| EC2 running | Yes | Yes | Yes |
| Public IPv4 | Assigned | Assigned | Assigned |
| Internet gateway | Attached | Attached | Attached |
| VPC-local route | Present | Present | Present |
| Internet default route | Present | Missing | Restored |
| Security group egress | Allowed | Allowed | Allowed |
| Network ACL | Allowed | Allowed | Allowed |
| HTTPS connectivity | Successful | Blocked by missing route | Successful |
| SSM managed node | Online | May lose connection | Online |

### Success Criteria

The incident is considered resolved when:

- The `0.0.0.0/0` route points to the attached IGW.
- The subnet uses the correct route table.
- The instance has a public IPv4 address.
- Outbound traffic is permitted.
- DNS resolution works.
- HTTPS connectivity succeeds from the instance.
- Systems Manager access is restored.

---

## 19. Production Engineering Considerations

### Common Public Subnet Internet Failures

| Symptom | Possible Cause |
|---|---|
| No internet access | Missing default route |
| Public subnet but no public IP | No public IPv4 assigned |
| Route target invalid | Wrong or detached internet gateway |
| Outbound traffic blocked | Security group egress restriction |
| Return traffic blocked | Network ACL restriction |
| Domain names fail | DNS resolver problem |
| HTTPS times out | Routing, filtering, or endpoint connectivity |
| SSM goes offline | Lost outbound access to SSM endpoints |

### Recommended Troubleshooting Order

1. Verify the instance is running.
2. Check the public IPv4 address.
3. Identify the associated subnet.
4. Inspect the subnet's effective route table.
5. Verify the internet gateway attachment.
6. Check security group egress.
7. Check network ACL inbound and outbound rules.
8. Verify operating-system routing.
9. Compare hostname connectivity with IP connectivity.
10. Apply the minimum necessary fix.
11. Verify the original request succeeds.

### Production Best Practices

- Manage VPC routing through Terraform or CloudFormation.
- Avoid editing production route tables without change review.
- Use dedicated route tables for workloads requiring separate routing policies.
- Limit administrative access.
- Monitor network reachability.
- Use VPC Flow Logs and Reachability Analyzer when appropriate.
- Keep recovery access available before network changes.
- Avoid creating unnecessary NAT gateways or public exposure.

---

## 20. Interview Questions and Answers

### Q1. What makes a subnet public in AWS?

A subnet is public when its associated route table includes a route to an internet gateway.

### Q2. Does a public IP alone provide internet access?

No. Correct routing, gateway configuration, and network filtering are also required.

### Q3. What route normally provides outbound IPv4 internet access in a public subnet?

```text
0.0.0.0/0 → Internet Gateway
```

### Q4. What does `0.0.0.0/0` represent?

It represents all IPv4 destination addresses and is commonly used as a default route.

### Q5. What is the difference between a route table and a security group?

A route table selects network destinations and next hops. A security group determines whether specified network traffic is permitted.

### Q6. Why can an EC2 instance pass status checks while having no internet access?

Instance status checks evaluate instance and infrastructure health, not the correctness of every application network path.

### Q7. Can an internet gateway be attached but still not provide internet access?

Yes. The subnet may lack the required default route or the instance may lack a public IP.

### Q8. Why did Session Manager lose connectivity during this lab?

The SSM Agent relied on outbound access to public Systems Manager endpoints, and removing the internet route interrupted that path.

### Q9. What is the difference between Linux routing and VPC route tables?

Linux routing operates within the guest OS. VPC route tables control supported routing decisions in the AWS virtual network.

### Q10. How can you troubleshoot public subnet internet access?

Inspect the public IP, subnet association, route table, internet gateway, security group, NACL, DNS, and Linux routing.

### Q11. Would a NAT gateway fix this public subnet problem?

Not as the intended fix. The correct design for this public subnet is to restore its route to the attached internet gateway.

### Q12. How would you explain this project in an interview?

> I created a dedicated AWS VPC with a public subnet, an internet gateway, a route table, and an EC2 instance managed through Session Manager. After confirming internet connectivity, I intentionally removed the subnet's default route to reproduce a connectivity failure. I investigated the route table, internet gateway, public IP, security group, and network ACL. The root cause was the missing `0.0.0.0/0` route to the internet gateway. I restored it and verified that HTTPS and Session Manager connectivity worked again. Finally, I cleaned up the lab resources.

---

## 21. Cleanup

**Warning:** Verify ownership before deleting any resources. These commands are intended only for resources created in Lab 01.

Run from WSL2.

### Step 1 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Lab Tags

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{ID:VpcId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm that the resources belong to `VPC-Troubleshooting-Lab01`.

### Step 3 — Record the Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check automatic deletion:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 4 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Confirm that this is the dedicated Lab 01 role.

Check the instance profile is not actively used by another instance:

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=iam-instance-profile.arn,Values=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):instance-profile/${PROFILE_NAME}" \
  --query 'IamInstanceProfileAssociations[].{Instance:InstanceId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 6 — Remove IAM Resources

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

```bash
aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 7 — Delete the Security Group

Check network interface dependencies:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

If there are no remaining dependencies:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Remove the Custom Route Table Association

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete the Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

Do not delete the VPC's main route table manually.

### Step 10 — Delete the Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Detach the Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete the Internet Gateway

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete the Dedicated VPC

Only after verifying no additional resources depend on it:

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected if the volume was automatically deleted:

```text
InvalidVolume.NotFound
```

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Security group | Deleted |
| Custom route table | Deleted |
| Public subnet | Deleted |
| Internet gateway | Detached and deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 22. Repository Structure

```text
01-public-subnet-no-internet/
│
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy allowing EC2 to assume the SSM role |

Do not commit credentials, SSH private keys, or sensitive instance data.

---

## 23. Lessons Learned

This lab demonstrated that public subnet internet connectivity requires multiple AWS networking components to work together.

The EC2 instance had a public IPv4 address, an attached internet gateway, and an outbound security group configuration that allowed traffic. However, internet connectivity was disrupted because the subnet's route table did not contain the necessary default route.

The investigation focused on checking individual networking components instead of randomly changing configurations.

Restoring the `0.0.0.0/0` route to the internet gateway corrected the routing problem.

The exercise also highlighted that losing internet access can affect management tools such as Systems Manager when they rely on public AWS service endpoints.

**Key lesson:** A public IPv4 address and an attached internet gateway are not enough. The associated subnet route table must direct internet-bound traffic to the gateway.

---

## 24. Skills Demonstrated

- Amazon VPC troubleshooting
- Public subnet configuration
- Internet gateway management
- AWS route table troubleshooting
- Subnet route table associations
- EC2 public IPv4 networking
- Security group inspection
- Network ACL inspection
- AWS Systems Manager Session Manager
- IAM roles and instance profiles
- Linux networking diagnostics
- AWS CLI v2
- Controlled network fault simulation
- Root cause analysis
- Connectivity remediation
- AWS infrastructure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-001 |
| Problem | Public subnet cannot access internet |
| Simulated Root Cause | Missing default route |
| Affected Route | `0.0.0.0/0` |
| Correct Target | Internet Gateway |
| EC2 Public IPv4 | Assigned |
| IGW Attachment | Valid |
| Route After Remediation | Restored |
| DNS Verification | Successful |
| HTTPS Verification | Successful |
| SSM Connectivity | Restored |
| Cleanup | Lab resources deleted |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance in a public subnet cannot access the internet, verify the associated route table and internet gateway before changing security rules or operating-system settings. Restore the correct route, test connectivity from the instance, and document the outcome.
