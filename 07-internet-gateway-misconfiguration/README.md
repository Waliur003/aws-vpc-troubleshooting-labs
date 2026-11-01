# Lab 07 — Internet Gateway Misconfiguration

## Overview

This lab demonstrates how to investigate an Amazon VPC internet connectivity failure caused by a detached Internet Gateway (IGW).

An EC2 instance is deployed in a public subnet with a route table that directs internet-bound traffic to an Internet Gateway.

Initially, the instance can access external HTTPS services. We then simulate an Internet Gateway attachment problem in an isolated lab VPC.

The goal is to identify the missing IGW attachment, restore the correct configuration, and verify outbound internet connectivity.

**Troubleshooting workflow:**

Provision → Verify Connectivity → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-007 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl |
| VPC CIDR | `10.70.0.0/16` |
| Public Subnet | `10.70.1.0/24` |
| Internet Gateway | Attached initially, detached during fault |
| Default Route | `0.0.0.0/0 → IGW` |
| Simulated Failure | Internet Gateway detached from VPC |
| Root Cause | Missing IGW attachment |
| Remediation | Reattach IGW and verify routing |
| Verification | HTTPS connectivity and public IPv4 |
| Management | Systems Manager Session Manager |

---

## 1. Production Incident Scenario

A company hosts an application on an EC2 instance in a public subnet.

The instance needs outbound internet connectivity to download updates, access external APIs, and communicate with AWS service endpoints.

After a networking configuration change, the application cannot reach external services.

The engineer investigates and finds:

- The EC2 instance exists and can pass its status checks.
- The public subnet has a route table.
- The route table references an Internet Gateway.
- Security group outbound traffic is permitted.
- The Internet Gateway is no longer attached to the VPC.
- Internet connectivity is unavailable.

### Expected Behavior

```text
EC2 Instance
     |
     v
Public Subnet
     |
     v
Route Table
0.0.0.0/0 → IGW
     |
     v
Attached Internet Gateway
     |
     v
Internet
```

### Failure Behavior

```text
EC2 Instance
     |
     v
Public Subnet
     |
     v
Route Table
0.0.0.0/0 → IGW
     |
     v
Internet Gateway Detached
     |
     X
Internet Connectivity Fails
```

### Potential Business Impact

- External API requests fail.
- Application updates cannot be downloaded.
- Software deployment tasks may fail.
- Systems Manager connectivity may be interrupted.
- Application integrations become unavailable.

### Incident Objective

Identify the missing Internet Gateway attachment and restore the correct VPC internet path.

---

## 2. AWS Architecture

### Healthy Architecture

```text
                     Internet
                        |
                        v
                Internet Gateway
                   (Attached)
                        |
          +---------------------------+
          | AWS VPC                   |
          | 10.70.0.0/16              |
          |                           |
          | Public Subnet             |
          | 10.70.1.0/24              |
          |                           |
          | Route Table               |
          | 10.70.0.0/16 → local      |
          | 0.0.0.0/0 → IGW           |
          |                           |
          | EC2 Instance              |
          | Private + Public IPv4     |
          +---------------------------+
```

### Broken Architecture

```text
                     Internet
                        |
                        X
                Internet Gateway
                   (Detached)
                        X
          +---------------------------+
          | AWS VPC                   |
          | 10.70.0.0/16              |
          |                           |
          | Public Subnet             |
          | 10.70.1.0/24              |
          |                           |
          | Route Table               |
          | Default Route → IGW       |
          | Target Not Available      |
          |                           |
          | EC2 Instance              |
          | External Access Failed    |
          +---------------------------+
```

### Network Components

| Component | Purpose |
|---|---|
| VPC | Dedicated AWS network |
| Public subnet | Hosts the EC2 instance |
| Internet Gateway | Connects the VPC to the internet |
| Route table | Directs internet-bound traffic |
| EC2 instance | Application workload |
| Public IPv4 | Allows direct IPv4 communication through IGW |
| Security group | Controls instance traffic |
| IAM role | Grants Systems Manager permissions |
| Session Manager | Allows administration without inbound SSH |

---

## 3. Understanding Internet Gateways

An Internet Gateway is a horizontally scaled, highly available VPC component that provides a path between a VPC and the internet.

For an EC2 instance to communicate directly with the internet using IPv4, the following conditions generally must be satisfied:

1. An Internet Gateway is attached to the VPC.
2. The subnet's effective route table contains a valid default route to the IGW.
3. The instance has a public IPv4 or Elastic IP address.
4. Security group rules permit the required traffic.
5. Network ACLs permit request and response traffic.
6. The operating system and application networking are configured correctly.

### Internet Gateway vs. Route Table

An Internet Gateway provides an internet path.

A route table determines whether traffic is directed toward that gateway.

These are separate components, and both must be configured correctly.

### Internet Gateway Attachment States

Use the following command to check attachment information:

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

For an attached IGW, the response identifies the VPC.

For a detached IGW, the attachments array is empty.

### AWS Detachment Restriction

AWS may reject an attempt to detach an Internet Gateway while public IPv4 or Elastic IP mappings remain associated with resources in the VPC.

For this isolated experiment, we stop the disposable EC2 instance first and confirm the relevant dependencies have been released.

**Do not attempt to force an Internet Gateway detachment in a shared or production VPC.**

---

## 4. Prerequisites and Safety

### Required Tools

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Git
- EC2 and VPC permissions
- IAM role management permissions
- Systems Manager access

### Safety Requirements

- Use a dedicated VPC.
- Do not modify the default VPC.
- Do not detach an IGW used by other workloads.
- Verify resource ownership before modification.
- Do not open inbound SSH access.
- Stop the disposable instance before attempting detachment.
- Use the local AWS CLI as the recovery path.
- Clean up temporary resources.

### Cost Considerations

The lab can incur charges for EC2 compute, EBS storage, public IPv4 addresses, and data transfer.

No NAT gateway or paid VPC interface endpoint is required.

---

## 5. Prepare the Environment

Run in Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab07"

export VPC_NAME="cloud-lab07-vpc"
export SUBNET_NAME="cloud-lab07-public-subnet"
export IGW_NAME="cloud-lab07-igw"
export RT_NAME="cloud-lab07-public-rt"
export SG_NAME="cloud-lab07-sg"
export INSTANCE_NAME="cloud-lab07-ec2"

export ROLE_NAME="cloud-lab07-ssm-role"
export PROFILE_NAME="cloud-lab07-ssm-profile"

export VPC_CIDR="10.70.0.0/16"
export SUBNET_CIDR="10.70.1.0/24"
```

Verify your AWS account:

```bash
aws sts get-caller-identity
aws --version
```

### Step 2 — Choose Availability Zone

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select a supported Availability Zone:

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

If an existing Lab 07 VPC appears, inspect it before creating another.

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

Verify:

```bash
echo "$VPC_ID"
```

### Step 2 — Enable DNS

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

---

## 7. Create Public Subnet

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

Enable automatic public IPv4 assignment:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `PublicIP=True`.

---

## 8. Create and Attach Internet Gateway

### Step 1 — Create IGW

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Attach IGW

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
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the IGW is attached to the lab VPC.

---

## 9. Create Public Route Table

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

### Step 2 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Associate Subnet

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.70.0.0/16 → local
0.0.0.0/0    → IGW
```

---

## 10. Configure Security Group and IAM

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab07 internet gateway investigation" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: no inbound rules and outbound traffic permitted.

### Step 2 — Create EC2 Trust Policy

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

### Step 3 — Check Existing IAM Resources

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For new resources, `NoSuchEntity` is expected.

### Step 4 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 5 — Attach SSM Policy

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 6 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Verify:

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output table
```

Allow IAM propagation before launching EC2.

---

## 11. Launch the EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not launch a duplicate.

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

### Step 5 — Verify Public IPv4

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: instance running with a private and public IPv4.

---

## 12. Establish Healthy Internet Connectivity

### Step 1 — Check SSM Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration: `Online`.

### Step 2 — Connect Through Session Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

The CLI method requires the Session Manager plugin. Alternatively, use the AWS Console.

### Step 3 — Test DNS and HTTPS

Inside EC2:

```bash
ip route
getent ahostsv4 example.com
```

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTPS response.

### Step 4 — Verify Public Egress IP

```bash
curl -4 -fsS \
  --max-time 10 \
  https://checkip.amazonaws.com
```

Expected: the instance's current public IPv4.

Exit:

```bash
exit
```

---

## 13. Reproduce the Internet Gateway Misconfiguration

### Step 1 — Stop EC2

AWS may reject an IGW detach request if public IPv4 mappings remain in use. Stop the dedicated EC2 instance before detaching.

```bash
aws ec2 stop-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-stopped \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

The automatically assigned public IPv4 is normally released when the instance stops.

### Step 2 — Verify IGW Ownership

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].{ID:InternetGatewayId,Tags:Tags,Attachments:Attachments}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the IGW belongs to Lab 07.

### Step 3 — Detach Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

If AWS reports a dependency violation, inspect the relevant public IPv4 mappings and other resources before proceeding. Do not force deletion or change unrelated infrastructure.

### Step 4 — Verify IGW Is Detached

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 5 — Start EC2

```bash
aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Inspect EC2 Networking

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

Because the instance was stopped and restarted, its public IPv4 may differ or be absent. Record the actual response.

### Expected Failure

The VPC does not have an attached Internet Gateway.

Therefore, direct IPv4 internet connectivity through that IGW is unavailable.

Session Manager may not register or reconnect because the instance cannot reach the required public AWS endpoints.

---

## 14. Troubleshooting Investigation

### Check 1 — Verify EC2 Status

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

EC2 status checks may remain healthy.

### Check 2 — Find Internet Gateways Attached to VPC

```bash
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[].{ID:InternetGatewayId,Attachments:Attachments}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: no Internet Gateway attached to the VPC.

### Check 3 — Inspect the Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

The IGW route may appear in a `blackhole` state if the target is unavailable. Inspect the actual route state returned by AWS.

### Check 4 — Verify Subnet Association

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Verify the intended public route table remains associated.

### Check 5 — Inspect Security Group Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound HTTPS permitted.

### Check 6 — Inspect NACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkAcls[].Entries' \
  --output json \
  --region "$AWS_REGION"
```

The default NACL should remain unchanged.

### Check 7 — Inspect SSM Connectivity

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

SSM registration may be missing or show `ConnectionLost`, depending on timing.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Running |
| VPC | Exists |
| Public subnet | Exists |
| Route table | References IGW |
| IGW attachment | Missing |
| Security group | Outbound permitted |
| Network ACL | Default configuration |
| SSM connectivity | May fail |
| Root cause | Detached Internet Gateway |

---

## 15. Root Cause Analysis

### Root Cause

The Internet Gateway was detached from the VPC, removing the intended internet path.

### Technical Explanation

The subnet route table identifies the Internet Gateway as the next hop for internet-bound traffic.

However, the gateway must actually be attached to the VPC.

A route referencing a gateway does not independently provide connectivity if the gateway is unavailable.

### Five Whys

1. **Why did the EC2 workload lose internet access?** The expected internet path was unavailable.
2. **Why was the internet path unavailable?** The VPC had no attached Internet Gateway.
3. **Why didn't the route table solve the issue?** The route's gateway target was detached.
4. **Why could EC2 remain healthy?** Instance health checks do not validate all external traffic paths.
5. **How can the issue be prevented?** Manage IGW attachment and routing through infrastructure as code and validate network connectivity after changes.

### Root Cause Flow

```text
EC2 Outbound Request
         |
         v
Public Subnet
         |
         v
Default Route to IGW
         |
         v
Internet Gateway Detached
         |
         X
No Internet Path
```

---

## 16. Remediation

### Step 1 — Reattach the Internet Gateway

From WSL2:

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Attachment

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the IGW is attached to the correct VPC.

### Step 3 — Verify Route State

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Expected: an active default route targeting the IGW.

If the default route is missing, recreate it:

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Only create this route if it does not already exist.

### Step 4 — Verify Public IPv4

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PublicIP:PublicIpAddress}' \
  --output json \
  --region "$AWS_REGION"
```

If the instance has no public IPv4, investigate the network interface and addressing configuration.

Reattaching an Internet Gateway alone does not guarantee a public IPv4 address will be assigned.

If needed, a temporary Elastic IP can be allocated and associated with the lab instance. Record the allocation ID and release it during cleanup.

### Step 5 — Verify Session Manager

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after recovery: `Online`.

### Step 6 — Verify DNS and HTTPS

Reconnect through Session Manager.

Inside EC2:

```bash
getent ahostsv4 example.com
```

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTPS response.

### Step 7 — Verify Public Egress IP

```bash
curl -4 -fsS \
  --max-time 10 \
  https://checkip.amazonaws.com
```

Expected: the instance's current public egress IPv4.

---

## 17. Verification Matrix

| Check | Healthy | IGW Detached | After Fix |
|---|---|---|---|
| EC2 instance | Running | Running after restart | Running |
| Public subnet | Exists | Exists | Exists |
| Route table | Configured | IGW target may be unavailable | Active |
| IGW attachment | Attached | Detached | Attached |
| Public IPv4 | Present | Must inspect after restart | Present or restored |
| Outbound HTTPS | Working | Unavailable through IGW | Working |
| SSM | Online | May disconnect | Online |

### Success Criteria

The incident is resolved when:

- The Internet Gateway is attached to the correct VPC.
- The subnet's effective default route targets the attached IGW.
- The route is active.
- The EC2 instance has appropriate public IPv4 addressing.
- Security groups and NACLs permit required traffic.
- Systems Manager reconnects.
- External HTTPS requests succeed.

---

## 18. Production Engineering Best Practices

### Internet Gateway Troubleshooting Checklist

1. Verify instance status.
2. Identify the instance's VPC and subnet.
3. Check whether an Internet Gateway is attached.
4. Inspect the subnet's effective route table.
5. Confirm the default route targets the correct IGW.
6. Verify route state.
7. Confirm public IPv4 or Elastic IP assignment.
8. Inspect security group egress.
9. Check NACL rules.
10. Test DNS and HTTPS.
11. Apply the minimum required remediation.
12. Verify end-to-end connectivity.

### Preventing IGW Misconfiguration

- Manage networking resources with Terraform or CloudFormation.
- Use infrastructure change reviews.
- Keep clear resource ownership tags.
- Avoid manual changes in shared production VPCs.
- Use application-level connectivity checks.
- Monitor changes to Internet Gateway attachments and route tables.
- Restrict permissions to modify shared network infrastructure.
- Keep a recovery path available outside the affected VPC.

---

## 19. Interview Questions and Answers

### Q1. What is an Internet Gateway?

An Internet Gateway is a VPC component that provides a path between the VPC and the internet.

### Q2. Does attaching an IGW automatically make a subnet public?

No. A subnet must also have an effective route to the IGW, and instances need appropriate public addressing and security configuration for direct IPv4 internet access.

### Q3. What happens when an IGW is detached?

The VPC loses connectivity through that Internet Gateway.

### Q4. Can AWS prevent an IGW from being detached?

Yes. AWS can block detachment when public IPv4 or Elastic IP mappings remain associated with resources in the VPC.

### Q5. Why was the EC2 instance stopped in this lab?

To release its automatically assigned public IPv4 and avoid violating IGW detachment dependencies.

### Q6. Why might the public IPv4 change after restarting EC2?

An automatically assigned public IPv4 address is normally released when an instance stops, and a new one can be assigned on restart.

### Q7. What is a blackhole route?

A route whose target is unavailable, preventing traffic matching that route from reaching the intended next hop.

### Q8. Can EC2 status checks pass while internet access fails?

Yes. EC2 status checks do not validate all external network connectivity.

### Q9. Is `0.0.0.0/0 → IGW` enough for direct internet access?

No. The IGW must be attached, the route must be active, the instance needs appropriate public IPv4 addressing, and security controls must allow traffic.

### Q10. How does Lab 07 differ from Lab 01?

Lab 01 investigates a missing route to an attached IGW. Lab 07 investigates a missing IGW attachment while the route table is intended to reference that gateway.

### Q11. How do you inspect IGW attachments using AWS CLI?

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

### Q12. How would you explain this lab in an interview?

> I created an isolated AWS VPC with a public subnet, Internet Gateway, route table, and EC2 instance. I verified that the instance could access external HTTPS services. Then I stopped the disposable instance and detached the Internet Gateway to simulate a networking misconfiguration. After restarting EC2, I investigated the gateway attachment, effective route table, and instance status. I identified the detached Internet Gateway as the root cause. I reattached it, verified the route and public IP configuration, and tested HTTPS connectivity again.

---

## 20. Cleanup

**Important:** Confirm the AWS account, project tags, and resource IDs before running destructive commands.

### Step 1 — Verify Ownership

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

Confirm `Project=VPC-Troubleshooting-Lab07`.

### Step 2 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check deletion settings:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 3 — Terminate the Instance

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

If an Elastic IP was allocated during recovery, release that lab-owned allocation after verifying it is no longer associated with a resource.

### Step 4 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Ensure the instance profile is not used by another workload.

### Step 5 — Delete IAM Resources

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

### Step 6 — Delete Security Group

Check dependencies:

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

### Step 7 — Disassociate Custom Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

Do not manually delete the VPC's main route table.

### Step 9 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Detach IGW if Attached

Check:

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

If attached:

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

If already detached, skip this operation.

### Step 11 — Delete Internet Gateway

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Verify VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Confirm no remaining resources depend on the dedicated VPC.

### Step 13 — Delete VPC

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

An `InvalidVolume.NotFound` result indicates that the volume no longer exists.

### Step 15 — Verify No Active Lab EC2 Instances

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

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Removed |
| Security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Custom route table | Deleted |
| Public subnet | Deleted |
| Internet Gateway | Deleted |
| Dedicated VPC | Deleted |
| Temporary Elastic IP, if created | Released |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
07-internet-gateway-misconfiguration/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Lab setup, incident investigation, failure simulation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | EC2 trust policy used for the Session Manager role |

Do not commit AWS credentials, access keys, or other sensitive account information.

---

## 22. Lessons Learned

This lab demonstrates that a public subnet route alone does not guarantee internet connectivity.

The route table can reference an Internet Gateway, but the gateway must also be correctly attached to the VPC.

The lab also highlights an important AWS restriction: Internet Gateway detachment can be blocked when public IPv4 mappings remain in use.

Another lesson is that stopping and restarting an EC2 instance can change its automatically assigned public IPv4 address.

The troubleshooting process requires checking gateway attachment, effective routing, addressing, and application connectivity separately.

**Key Lesson:** Always verify the Internet Gateway attachment in addition to the route table, public IPv4 configuration, and security controls when diagnosing public subnet internet failures.

---

## 23. Skills Demonstrated

- Amazon VPC configuration
- Internet Gateway troubleshooting
- IGW attachment and detachment
- EC2 public subnet networking
- Route table investigation
- Public IPv4 address management
- Security group inspection
- Network ACL inspection
- AWS Systems Manager
- AWS CLI v2
- Linux connectivity testing
- Controlled infrastructure fault simulation
- Root cause analysis
- Incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-007 |
| Problem | EC2 internet connectivity failure |
| Root Cause | Detached Internet Gateway |
| Default Route | `0.0.0.0/0 → IGW` |
| Remediation | Reattach IGW |
| Public IPv4 | Verified or restored |
| Route State | Active |
| HTTPS After Fix | Successful |
| SSM After Fix | Online |
| Cleanup | Dedicated resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** A VPC Internet Gateway must be attached and reachable through the subnet's effective route table. Public addressing and security rules must also be correct before an EC2 instance can communicate directly with the internet.
