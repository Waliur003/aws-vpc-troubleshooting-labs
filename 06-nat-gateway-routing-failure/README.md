# Lab 06 — NAT Gateway Routing Failure

## Overview

This lab demonstrates how to troubleshoot an AWS NAT Gateway routing failure that prevents a private EC2 instance from accessing the internet.

The private EC2 instance does not have a public IPv4 address. It relies on a NAT gateway deployed in a public subnet to reach external services.

Although the NAT gateway is available and the private subnet has a correct default route to it, internet connectivity fails because the NAT gateway's public subnet is missing its route to the internet gateway.

We will build the infrastructure, verify working connectivity, intentionally introduce the routing failure, investigate the root cause, restore the route, and verify recovery.

**Workflow:** Provision → Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | `INC-VPC-006` |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, NAT Gateway, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Linux network utilities |
| VPC CIDR | `10.60.0.0/16` |
| Public Subnet | `10.60.1.0/24` |
| Private Subnet | `10.60.2.0/24` |
| NAT Type | Public NAT Gateway |
| NAT Address | Elastic IP |
| Fault | Missing public subnet route to IGW |
| Remediation | Restore `0.0.0.0/0 → IGW` |
| Verification | HTTPS and NAT Elastic IP |
| Management | Systems Manager Session Manager |

---

## 1. Production Incident Scenario

A company's application runs on an EC2 instance in a private subnet.

The application requires outbound internet access for external APIs, software updates, and service integrations.

The company uses a public NAT gateway to provide internet access without assigning a public IP to the application instance.

After a networking change, outbound requests begin to fail.

The engineer investigates and discovers:

- The private EC2 instance is running.
- The instance has only a private IPv4 address.
- The NAT gateway is available.
- The NAT gateway has an Elastic IP.
- The private subnet routes `0.0.0.0/0` to the NAT gateway.
- The internet gateway is attached to the VPC.
- The NAT gateway's public subnet has no default route to the internet gateway.

### Expected Behavior

```text
Private EC2
     |
     v
Private Route Table
0.0.0.0/0 → NAT Gateway
     |
     v
Public NAT Gateway
     |
     v
Public Route Table
0.0.0.0/0 → Internet Gateway
     |
     v
Internet
```

### Failure Behavior

```text
Private EC2
     |
     v
Private Route Table
     |
     v
NAT Gateway (Available)
     |
     v
Public Subnet Route Table
     |
     X
Missing Default Route to IGW
     |
     X
Internet Access Fails
```

### Business Impact

- External API requests fail.
- Application integrations stop working.
- Package downloads and updates fail.
- Deployment automation may fail.
- Systems Manager access may be interrupted.
- Application availability can be affected.

### Incident Objective

Identify which part of the NAT gateway's outbound routing path is broken and restore internet access without assigning a public IPv4 address to the private EC2 instance.

---

## 2. AWS Architecture

```text
                         Internet
                            |
                            |
                     Internet Gateway
                            |
                   [Missing Route]
                            X
                            |
              +---------------------------+
              | AWS VPC                   |
              | 10.60.0.0/16              |
              |                           |
              | PUBLIC SUBNET             |
              | 10.60.1.0/24              |
              |                           |
              | NAT Gateway              |
              | Elastic IP                |
              |                           |
              | Public Route Table        |
              | 10.60.0.0/16 → local      |
              | 0.0.0.0/0 → IGW           |
              | [Removed During Failure]  |
              |                           |
              |            |              |
              |            |              |
              |            v              |
              | PRIVATE SUBNET            |
              | 10.60.2.0/24              |
              |                           |
              | Private EC2               |
              | No Public IPv4            |
              |                           |
              | Private Route Table       |
              | 10.60.0.0/16 → local      |
              | 0.0.0.0/0 → NAT Gateway   |
              +---------------------------+
```

### Resource Configuration

| Resource | Purpose |
|---|---|
| Dedicated VPC | Isolated test network |
| Public subnet | Hosts the NAT gateway |
| Private subnet | Hosts the EC2 workload |
| Internet gateway | Connects the VPC to the internet |
| NAT gateway | Provides outbound IPv4 translation |
| Elastic IP | Public address used by NAT |
| Public route table | Routes NAT subnet traffic to IGW |
| Private route table | Routes private EC2 traffic to NAT |
| Security group | Controls EC2 traffic |
| IAM role | Provides SSM permissions |
| Session Manager | Enables remote management without SSH |

---

## 3. Understanding NAT Gateway Routing

A NAT gateway allows private IPv4 workloads to initiate outbound connections without requiring public IPv4 addresses on those workloads.

For this architecture to work, two route tables must be configured correctly.

### Public Subnet Route Table

```text
Destination       Target
10.60.0.0/16      local
0.0.0.0/0         Internet Gateway
```

### Private Subnet Route Table

```text
Destination       Target
10.60.0.0/16      local
0.0.0.0/0         NAT Gateway
```

### Why Both Routes Matter

The private subnet route sends internet-bound traffic to the NAT gateway.

The public subnet route allows the public NAT gateway to reach the internet gateway.

If either route is missing, outbound internet connectivity can fail.

### Lab 02 vs. Lab 06

| Feature | Lab 02 | Lab 06 |
|---|---|---|
| Failed component | Private route table | Public route table |
| Route removed | `0.0.0.0/0 → NAT` | `0.0.0.0/0 → IGW` |
| NAT gateway | Available | Available |
| Private subnet route | Missing | Correct |
| NAT subnet internet route | Correct | Missing |
| Troubleshooting focus | Private subnet routing | Full NAT egress path |

---

## 4. Prerequisites and Cost Awareness

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC management permissions
- IAM role and instance profile permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use an isolated lab VPC.
- Do not modify your default VPC.
- Verify project tags before modifying route tables.
- Keep inbound SSH closed.
- Do not assign a public IP to the private EC2.
- Perform fault injection from the local AWS CLI.
- Clean up resources after completing the lab.

### AWS Cost Warning

This lab creates resources that can incur charges:

- NAT gateway hourly usage
- NAT gateway data processing
- Elastic IP/public IPv4
- EC2 instance
- EBS root volume
- Data transfer

**Important:** Terminating EC2 does not delete the NAT gateway or release its Elastic IP.

---

## 5. Prepare the Environment

Run these commands from Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab06"

export VPC_CIDR="10.60.0.0/16"
export PUBLIC_CIDR="10.60.1.0/24"
export PRIVATE_CIDR="10.60.2.0/24"

export VPC_NAME="cloud-lab06-vpc"
export PUBLIC_SUBNET_NAME="cloud-lab06-public-subnet"
export PRIVATE_SUBNET_NAME="cloud-lab06-private-subnet"

export IGW_NAME="cloud-lab06-igw"
export NAT_NAME="cloud-lab06-nat"

export PUBLIC_RT_NAME="cloud-lab06-public-rt"
export PRIVATE_RT_NAME="cloud-lab06-private-rt"

export SG_NAME="cloud-lab06-sg"
export INSTANCE_NAME="cloud-lab06-private-ec2"

export ROLE_NAME="cloud-lab06-ssm-role"
export PROFILE_NAME="cloud-lab06-ssm-profile"
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

Choose a supported AZ:

```bash
export LAB_AZ="us-east-1a"
```

### Step 3 — Check for Existing Lab VPC

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

If the lab VPC already exists, inspect and reuse it instead of creating a duplicate.

---

## 6. Create the VPC and Subnets

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

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

### Step 3 — Create Public Subnet

```bash
export PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=$PUBLIC_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet

```bash
export PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=$PRIVATE_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Disable Public IP Assignment on Private Subnet

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --no-map-public-ip-on-launch \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-subnets \
  --subnet-ids "$PUBLIC_SUBNET_ID" "$PRIVATE_SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch}' \
  --output table \
  --region "$AWS_REGION"
```

---

## 7. Configure Public Internet Routing

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

### Step 2 — Create Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=$PUBLIC_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Add IGW Route

```bash
aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Associate Public Subnet

```bash
export PUBLIC_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify that the public route table contains the local route and the IGW route.

---

## 8. Create NAT Gateway

### Step 1 — Check Existing NAT Gateways

```bash
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'NatGateways[].{ID:NatGatewayId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create duplicates.

### Step 2 — Allocate Elastic IP

```bash
export EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query AllocationId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-addresses \
  --allocation-ids "$EIP_ALLOC_ID" \
  --output json \
  --region "$AWS_REGION"
```

### Step 3 — Create Public NAT Gateway

```bash
export NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --allocation-id "$EIP_ALLOC_ID" \
  --connectivity-type public \
  --tag-specifications \
  "ResourceType=natgateway,Tags=[{Key=Name,Value=$NAT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query NatGateway.NatGatewayId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for Availability

```bash
aws ec2 wait nat-gateway-available \
  --nat-gateway-ids "$NAT_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify NAT

```bash
aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[].{ID:NatGatewayId,State:State,Subnet:SubnetId,Addresses:NatGatewayAddresses}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: NAT gateway `available`, deployed in the public subnet with the allocated Elastic IP.

---

## 9. Configure Private Routing

### Step 1 — Create Private Route Table

```bash
export PRIVATE_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=$PRIVATE_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Add NAT Route

```bash
aws ec2 create-route \
  --route-table-id "$PRIVATE_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Associate Private Subnet

```bash
export PRIVATE_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_RT_ID" \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Compare Route Tables

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" "$PRIVATE_RT_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
PUBLIC ROUTE TABLE
10.60.0.0/16 → local
0.0.0.0/0    → IGW

PRIVATE ROUTE TABLE
10.60.0.0/16 → local
0.0.0.0/0    → NAT Gateway
```

---

## 10. Configure Security Group and IAM

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "VPC Lab06 private EC2 security group" \
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

Expected: no inbound rules, outbound traffic allowed.

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

To save it locally:

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

### Step 3 — Check IAM Resource Names

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For a new lab, `NoSuchEntity` is expected.

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

## 11. Launch Private EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

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

Only launch a new instance if none already exists.

### Step 3 — Launch EC2 Without Public IPv4

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$PRIVATE_SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify No Public IPv4

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `PublicIP` is `null`.

---

## 12. Establish Healthy Connectivity

### Step 1 — Check SSM Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration: `Online`.

### Step 2 — Connect

Using EC2 Console → Connect → Session Manager, or:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

The CLI method requires the Session Manager plugin and appropriate operator permissions.

### Step 3 — Inspect Linux Networking

Inside EC2:

```bash
ip -br addr
ip route
getent ahostsv4 example.com
```

Expected: normal private IP configuration and successful DNS lookup.

### Step 4 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: an HTTP response.

### Step 5 — Verify NAT Public Address

From WSL2, retrieve the NAT Elastic IP:

```bash
aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
  --output text \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
curl -4 -fsS \
  --connect-timeout 5 \
  --max-time 10 \
  https://checkip.amazonaws.com
```

Expected: the NAT Elastic IP, assuming no additional proxy or egress path exists.

### Step 6 — Start Connectivity Recorder

The recorder helps capture the failure even if Session Manager disconnects.

Inside EC2:

```bash
sudo systemd-run \
  --unit=vpc-lab06-probe \
  --collect \
  /bin/bash -c 'for i in $(seq 1 72); do
    printf "%s " "$(date -u +%FT%TZ)" >> /var/tmp/vpc-lab06-probe.log
    if /usr/bin/curl -4 -fsS \
       --connect-timeout 2 --max-time 5 \
       https://example.com/ -o /dev/null; then
      echo HTTPS_OK >> /var/tmp/vpc-lab06-probe.log
    else
      echo HTTPS_FAILED >> /var/tmp/vpc-lab06-probe.log
    fi
    sleep 10
  done'
```

Inspect:

```bash
sudo tail /var/tmp/vpc-lab06-probe.log
```

Expected initial entries: `HTTPS_OK`.

Exit Session Manager:

```bash
exit
```

---

## 13. Reproduce NAT Gateway Routing Failure

### Step 1 — Verify Route Table Associations

From WSL2:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" "$PRIVATE_RT_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the public route table is associated only with the Lab 06 NAT subnet and the private table only with the lab private subnet.

### Step 2 — Remove the Public IGW Route

```bash
aws ec2 delete-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --region "$AWS_REGION"
```

This is the intentional failure.

### Step 3 — Verify the Public Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.60.0.0/16 → local
```

The internet gateway route is missing.

### Step 4 — Verify the Private NAT Route Remains

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.60.0.0/16 → local
0.0.0.0/0    → NAT Gateway
```

### Step 5 — Check NAT Gateway Status

```bash
aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{ID:NatGatewayId,State:State,Subnet:SubnetId}' \
  --output json \
  --region "$AWS_REGION"
```

The NAT gateway can remain `available` while the subnet routing prevents internet access.

### Step 6 — Check EC2 and SSM

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Check Systems Manager:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

SSM may eventually show `ConnectionLost`. Reporting can lag.

### Expected Findings

| Component | Finding |
|---|---|
| EC2 | Running |
| Public IPv4 on EC2 | None |
| NAT gateway | Available |
| NAT Elastic IP | Associated |
| Private subnet NAT route | Correct |
| Internet gateway | Attached |
| Public subnet IGW route | Missing |
| HTTPS access | Failed |
| Root cause | Incorrect public subnet routing |

---

## 14. Troubleshooting Investigation

### Check 1 — Verify NAT Gateway Placement

```bash
aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{State:State,Subnet:SubnetId,Addresses:NatGatewayAddresses}' \
  --output json \
  --region "$AWS_REGION"
```

Ensure the NAT gateway is deployed in `$PUBLIC_SUBNET_ID`.

### Check 2 — Verify Internet Gateway Attachment

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: attached to the correct VPC.

### Check 3 — Verify Effective Public Route Table

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$PUBLIC_SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `$PUBLIC_RT_ID`, missing the IGW default route.

### Check 4 — Verify Private Route Table

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: default route still points to NAT.

### Check 5 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound traffic permitted.

### Check 6 — Verify Network ACLs

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Associations:Associations,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

The new VPC's default NACL should permit traffic, because we have not changed it.

### Investigation Conclusion

The private subnet, NAT gateway, Elastic IP, security group, and internet gateway attachment are correctly configured.

The fault is the missing default internet route in the NAT gateway's public subnet.

---

## 15. Root Cause Analysis

### Root Cause

The public subnet containing the NAT gateway no longer had a default route directing internet-bound IPv4 traffic to the attached internet gateway.

### Technical Explanation

The private EC2 instance sends traffic toward the NAT gateway using its default route.

The NAT gateway requires a working outbound path through the public subnet and internet gateway.

When the public subnet's default route is removed, the NAT gateway cannot complete the required internet path.

### Five Whys

1. **Why did the private application lose internet access?** Outbound HTTPS traffic failed.
2. **Why did NAT not restore connectivity?** NAT's subnet had no internet gateway route.
3. **Why was the private route insufficient?** It only directed traffic to NAT, not through the complete internet path.
4. **Why did NAT remain available?** NAT resource availability does not confirm correct route table configuration.
5. **How could this be prevented?** Validate both route tables with infrastructure as code, change reviews, and end-to-end connectivity tests.

### Root Cause Flow

```text
Private EC2
    |
    v
Private Route Table
    |
    v
NAT Gateway
    |
    v
Public Subnet Route Table
    |
    v
Missing 0.0.0.0/0 Route
    |
    X
Internet Traffic Fails
```

---

## 16. Remediation

### Step 1 — Restore IGW Default Route

From WSL2:

```bash
aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Public Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.60.0.0/16 → local
0.0.0.0/0    → Internet Gateway
```

### Step 3 — Verify Private Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected: NAT default route remains.

### Step 4 — Confirm SSM Reconnection

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after reconnection: `Online`.

### Step 5 — Review Connectivity Recorder

Reconnect to EC2 through Session Manager.

```bash
sudo cat /var/tmp/vpc-lab06-probe.log
```

A successful experiment may show:

```text
HTTPS_OK
HTTPS_OK
HTTPS_FAILED
HTTPS_FAILED
HTTPS_OK
```

These are illustrative statuses. Use the actual timestamped observations from your instance.

### Step 6 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

### Step 7 — Verify NAT Elastic IP

```bash
curl -4 -fsS \
  --connect-timeout 5 \
  --max-time 10 \
  https://checkip.amazonaws.com
```

Expected: the NAT gateway's public Elastic IP.

Exit:

```bash
exit
```

---

## 17. Verification Matrix

| Check | Healthy | Failure | Restored |
|---|---|---|---|
| Private EC2 | Running | Running | Running |
| Public IPv4 on EC2 | None | None | None |
| NAT gateway | Available | Available | Available |
| Elastic IP | Associated | Associated | Associated |
| Private route to NAT | Present | Present | Present |
| Public route to IGW | Present | Missing | Restored |
| Outbound HTTPS | Working | Failed | Working |
| SSM | Online | May disconnect | Online |
| Egress public IP | NAT EIP | Unavailable | NAT EIP |

### Success Criteria

The incident is considered resolved when:

- The NAT gateway is available.
- The private route points to NAT.
- The NAT subnet's effective route table points to IGW.
- The EC2 instance has no public IPv4.
- Systems Manager reconnects.
- DNS and HTTPS requests succeed.
- The outbound public IPv4 matches the NAT EIP.
- Temporary resources are cleaned up.

---

## 18. Production Engineering Best Practices

### NAT Gateway Troubleshooting Checklist

1. Verify the private instance is running.
2. Check the private subnet's effective route table.
3. Confirm the default route targets the intended NAT gateway.
4. Verify NAT gateway state.
5. Verify NAT is located in the correct public subnet.
6. Check its Elastic IP association.
7. Inspect the public subnet's effective route table.
8. Confirm its default route targets the IGW.
9. Verify IGW attachment.
10. Inspect security groups and NACLs.
11. Test DNS and HTTPS from the private instance.
12. Apply the minimum required correction.

### High Availability Considerations

A single NAT gateway creates an availability dependency for private subnets that rely on it.

In production, consider deploying NAT gateways in multiple Availability Zones and routing private subnets to a suitable NAT gateway in their own AZ.

This helps reduce unnecessary cross-AZ dependency and improves resilience, although actual designs depend on cost and availability requirements.

### Infrastructure as Code

Manage NAT gateways and subnet routes with Terraform or CloudFormation.

Use code review, infrastructure validation, and post-deployment network tests before applying routing changes in production.

---

## 19. Interview Questions and Answers

### Q1. What does a NAT gateway do?

It enables private IPv4 workloads to initiate outbound connections without assigning them public IPv4 addresses.

### Q2. Why does a public NAT gateway need an internet gateway?

The NAT gateway's public subnet needs a route through the IGW to access internet destinations.

### Q3. What is the correct default route in a private subnet?

```text
0.0.0.0/0 → NAT Gateway
```

### Q4. What is the correct default route in the public NAT subnet?

```text
0.0.0.0/0 → Internet Gateway
```

### Q5. Does an available NAT gateway guarantee internet connectivity?

No. Its route tables, gateway attachment, and relevant network filtering must also support the traffic.

### Q6. Can an EC2 instance without a public IPv4 address access the internet?

Yes. It can initiate outbound IPv4 traffic through a correctly configured public NAT gateway.

### Q7. Why might Systems Manager disconnect during this incident?

The private instance relies on NAT to access public Systems Manager endpoints. A broken NAT internet path interrupts that communication.

### Q8. What is the difference between Lab 02 and Lab 06?

Lab 02 breaks the private subnet's route to NAT. Lab 06 breaks the public NAT subnet's route to IGW while keeping the private NAT route intact.

### Q9. What happens if the NAT gateway has an EIP but no IGW route?

Internet-bound traffic cannot use the expected outbound internet path.

### Q10. Why is end-to-end connectivity testing important?

Resource status alone does not demonstrate that the complete network path works.

### Q11. What should engineers consider for NAT high availability?

Use an appropriate multi-AZ network design, including NAT gateway placement and per-subnet routing.

### Q12. How would you explain this lab in an interview?

> I created an AWS VPC with public and private subnets, an internet gateway, a NAT gateway, and a private EC2 instance. After confirming outbound HTTPS worked through NAT, I intentionally removed the internet route from the NAT gateway's public subnet. The private route still pointed to the available NAT gateway, but outbound connections failed. I investigated both route tables, NAT state, Elastic IP, and gateway attachment. I identified the missing public subnet route as the root cause, restored it, and verified HTTPS access and outbound NAT IP translation.

---

## 20. Cleanup

**Warning:** These commands must target only resources created for Lab 06. Confirm the account, tags, and resource IDs before deletion.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{ID:NatGatewayId,State:State,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `Project=VPC-Troubleshooting-Lab06`.

### Step 2 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination`:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 3 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete NAT Gateway

```bash
aws ec2 delete-nat-gateway \
  --nat-gateway-id "$NAT_ID" \
  --region "$AWS_REGION"

aws ec2 wait nat-gateway-deleted \
  --nat-gateway-ids "$NAT_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Release Elastic IP

Verify the allocation belongs to this lab and is no longer associated:

```bash
aws ec2 describe-addresses \
  --allocation-ids "$EIP_ALLOC_ID" \
  --output json \
  --region "$AWS_REGION"
```

Release:

```bash
aws ec2 release-address \
  --allocation-id "$EIP_ALLOC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Confirm the instance profile is not used by another active instance.

### Step 7 — Delete IAM Resources

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

### Step 8 — Delete Security Group

Check network interface dependencies:

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

### Step 9 — Disassociate Custom Route Tables

```bash
aws ec2 disassociate-route-table \
  --association-id "$PRIVATE_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Custom Route Tables

```bash
aws ec2 delete-route-table \
  --route-table-id "$PRIVATE_RT_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

The VPC's main route table should not be deleted manually.

### Step 11 — Delete Private and Public Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --region "$AWS_REGION"
```

If deletion reports dependencies, verify NAT gateway deletion and remaining network interfaces before retrying.

### Step 12 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Verify Remaining VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Confirm no remaining lab resources or shared dependencies exist.

### Step 14 — Delete Dedicated VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

`InvalidVolume.NotFound` indicates the volume has been deleted.

If it remains, verify ownership and attachment before taking further action.

### Step 16 — Verify No Active Lab Instances

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

Also confirm the NAT gateway is deleted and its Elastic IP allocation is released.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Private EC2 | Terminated |
| Root EBS | Removed |
| NAT gateway | Deleted |
| NAT Elastic IP | Released |
| Security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Public route table | Deleted |
| Private route table | Deleted |
| Public subnet | Deleted |
| Private subnet | Deleted |
| Internet gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
06-nat-gateway-routing-failure/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Infrastructure setup, failure simulation, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | IAM trust policy for the EC2 Systems Manager role |

Do not commit credentials, SSH private keys, or confidential account information.

---

## 22. Lessons Learned

This lab demonstrates that an available NAT gateway does not guarantee working internet connectivity.

The private subnet route can be correct while the NAT gateway's public subnet is misconfigured.

During the simulated failure, the private EC2 instance continued routing traffic toward NAT, but the NAT gateway lacked the public subnet route required for internet access.

Restoring the public route to the internet gateway corrected the intended path.

The exercise also showed why engineers should check actual end-to-end application connectivity rather than relying only on AWS resource availability states.

**Key Lesson:** When troubleshooting private subnet internet failures, verify both the route from the private subnet to NAT and the route from the NAT gateway's subnet to the internet gateway.

---

## 23. Skills Demonstrated

- AWS VPC network architecture
- Public and private subnet configuration
- NAT gateway troubleshooting
- Elastic IP management
- Internet gateway routing
- Route table investigation
- Private EC2 networking
- AWS CLI diagnostics
- Systems Manager Session Manager
- Linux connectivity testing
- NAT public IP verification
- Controlled network fault simulation
- Root cause analysis
- Incident remediation
- AWS cost-aware cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-006 |
| Problem | Private EC2 internet failure |
| NAT Gateway State | Available |
| Private Route | Correct |
| Root Cause | Missing public subnet IGW route |
| Remediation | Restore `0.0.0.0/0 → IGW` |
| EC2 Public IPv4 | None |
| HTTPS After Fix | Successful |
| Egress Public IP | NAT Elastic IP |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** NAT gateway troubleshooting requires checking the complete outbound network path. Even when the private route correctly targets an available NAT gateway, internet access can fail if the NAT gateway's public subnet does not route traffic to an internet gateway.
