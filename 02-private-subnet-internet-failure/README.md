# Lab 02 — Private Subnet Internet Failure

**Incident:** `INC-VPC-002`  
**Repository:** `aws-vpc-troubleshooting-labs`  
**AWS Region:** `us-east-1`  
**Difficulty:** Intermediate  
**Services:** Amazon VPC, EC2, NAT Gateway, Elastic IP, Internet Gateway, IAM, Systems Manager

## Overview

This hands-on lab investigates why an Amazon EC2 instance in a **private subnet** cannot reach the internet. The instance has **no public IPv4 address**; outbound IPv4 internet connectivity is provided by a **public NAT gateway** in a separate public subnet. We establish a working baseline, deliberately remove the private subnet's default route, diagnose the failure, restore it, and verify the fix.

> **Scope and evidence:** This document describes the reproducible procedure and **expected** findings. Replace example observations with your actual CLI output or screenshots. A successful `describe-instance-status` check does not prove application internet connectivity.

## Incident summary

| Field | Value |
|---|---|
| Incident ID | `INC-VPC-002` |
| Symptom | HTTPS requests from private EC2 time out |
| Affected component | Private subnet route table |
| Deliberate fault | Deleted `0.0.0.0/0 → nat-...` route |
| Root cause | No default IPv4 route to the NAT gateway |
| Remediation | Restore `0.0.0.0/0 → NAT Gateway` |
| Verification | Route inspected; DNS, HTTPS and NAT public egress IP tested |
| Recovery access | AWS CLI from WSL2, independent of the EC2 network path |

### Business impact

Without NAT egress, private workloads may fail when calling external APIs, downloading packages, or reaching public AWS service endpoints. Systems Manager Session Manager may also disconnect if the instance relies on NAT instead of interface VPC endpoints.

## Architecture

```text
                             Internet
                                |
                          Internet Gateway
                                |
                   VPC 10.20.0.0/16
                  /                   \
    Public subnet 10.20.1.0/24    Private subnet 10.20.2.0/24
       NAT Gateway + EIP            EC2 (private IPv4 only)
       Public route table           Private route table
       0.0.0.0/0 -> IGW             0.0.0.0/0 -> NAT
                  \                   /
                  Outbound: EC2 -> NAT -> IGW -> Internet
```

**Critical concepts:** A NAT gateway for internet egress resides in a public subnet, uses an Elastic IP, and relies on that subnet's route to an Internet Gateway. The private EC2 instance does not need a public IP. Security groups are stateful; network ACLs are stateless, so response traffic must also be allowed.

## Lab configuration

| Resource | Configuration |
|---|---|
| VPC | `10.20.0.0/16` |
| Public subnet | `10.20.1.0/24` |
| Private subnet | `10.20.2.0/24` |
| Public route | `0.0.0.0/0 → IGW` |
| Private route | `0.0.0.0/0 → NAT` |
| EC2 | `t3.micro`, Amazon Linux 2023 |
| Public EC2 IPv4 | None |
| Management | IAM instance profile + Session Manager via NAT |
| Security group | No inbound; default outbound permitted |

### Prerequisites

- AWS CLI v2 configured on Ubuntu WSL2, with authorized EC2/VPC/IAM/SSM permissions.
- Session Manager plugin or AWS Console Session Manager access.
- Git and GitHub for documenting completed lab work.
- Sufficient available account quota and a compatible Availability Zone.

**Cost and safety:** NAT gateways have hourly and per-GB processing costs, even with little traffic. EC2, EBS and public IPv4/Elastic IP charges may also apply. Use **only** a dedicated tagged lab VPC; never disrupt a shared or production route table. Record all created IDs. Do not delete shared assets.

## 1 — Initialize environment

From Ubuntu WSL2:

```bash
cd "/mnt/d/AWS Cloud/Troubleshooting Labs/VPC/aws-vpc-troubleshooting-labs"
mkdir -p 02-private-subnet-internet-failure
cd 02-private-subnet-internet-failure

export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab02"
export VPC_NAME="cloud-lab02-vpc"
export PUBLIC_SUBNET_NAME="cloud-lab02-public-subnet"
export PRIVATE_SUBNET_NAME="cloud-lab02-private-subnet"
export IGW_NAME="cloud-lab02-igw"
export NAT_NAME="cloud-lab02-nat"
export PUBLIC_RT_NAME="cloud-lab02-public-rt"
export PRIVATE_RT_NAME="cloud-lab02-private-rt"
export SG_NAME="cloud-lab02-private-sg"
export INSTANCE_NAME="cloud-lab02-private-ec2"
export ROLE_NAME="cloud-lab02-ssm-role"
export PROFILE_NAME="cloud-lab02-ssm-profile"
export VPC_CIDR="10.20.0.0/16"
export PUBLIC_CIDR="10.20.1.0/24"
export PRIVATE_CIDR="10.20.2.0/24"

aws sts get-caller-identity
```

Keep the terminal session open to preserve exported variables. Before creating each resource, search for a previous Lab 02 resource with the same project tag to avoid duplicates.

## 2 — Create the isolated VPC and subnets

Find a suitable Availability Zone:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' --output table --region "$AWS_REGION"
export LAB_AZ="us-east-1a"  # Replace if not offered for your account

aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' --output table --region "$AWS_REGION"
```

Proceed with creation **only if no matching lab VPC exists**:

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' --output text --region "$AWS_REGION")

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"

export PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_CIDR" --availability-zone "$LAB_AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PUBLIC_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")

export PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_CIDR" --availability-zone "$LAB_AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PRIVATE_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")

aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_ID" --map-public-ip-on-launch --region "$AWS_REGION"
aws ec2 modify-subnet-attribute --subnet-id "$PRIVATE_SUBNET_ID" --no-map-public-ip-on-launch --region "$AWS_REGION"

aws ec2 describe-subnets --subnet-ids "$PUBLIC_SUBNET_ID" "$PRIVATE_SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch}' \
  --output table --region "$AWS_REGION"
```

**Expected:** Public subnet auto-assigns public IPs; private subnet does not.

## 3 — Create the public internet path

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION"

export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PUBLIC_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
aws ec2 create-route --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$AWS_REGION"
export PUBLIC_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" --subnet-id "$PUBLIC_SUBNET_ID" \
  --query 'AssociationId' --output text --region "$AWS_REGION")
```

Check that the NAT gateway does not already exist, then allocate an Elastic IP and create NAT:

```bash
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'NatGateways[].{ID:NatGatewayId,State:State}' --output table --region "$AWS_REGION"

export EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
  --query 'AllocationId' --output text --region "$AWS_REGION")

export NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_ID" --allocation-id "$EIP_ALLOC_ID" \
  --connectivity-type public \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$NAT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")

aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"
aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{ID:NatGatewayId,State:State,Addresses:NatGatewayAddresses}' \
  --output json --region "$AWS_REGION"
```

**Expected:** NAT state `available`; public subnet has a route through the IGW.

## 4 — Configure private routing

```bash
export PRIVATE_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PRIVATE_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")

aws ec2 create-route --route-table-id "$PRIVATE_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" --region "$AWS_REGION"

export PRIVATE_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_RT_ID" --subnet-id "$PRIVATE_SUBNET_ID" \
  --query 'AssociationId' --output text --region "$AWS_REGION")

aws ec2 describe-route-tables --route-table-ids "$PUBLIC_RT_ID" "$PRIVATE_RT_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' --output json --region "$AWS_REGION"
```

**Expected:** Public default route points to IGW; private default route points to NAT. Both retain their local `10.20.0.0/16` route.

## 5 — Set up secure private EC2 access

The file [`ec2-trust-policy.json`](./ec2-trust-policy.json) permits the EC2 service to assume the dedicated lab role. The role's actual Systems Manager API permissions are supplied separately by `AmazonSSMManagedInstanceCore`.

```bash
# Only create these dedicated IAM resources if they do not already exist.
aws iam get-role --role-name "$ROLE_NAME"
aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME"

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
```

Create a dedicated SG (verify name availability first). Do not add any inbound rules:

```bash
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' --output text --region "$AWS_REGION"

export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" --description 'VPC Lab02 private EC2 SG' --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'GroupId' --output text --region "$AWS_REGION")

aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json --region "$AWS_REGION"
```

Launch one Amazon Linux 2023 instance, **without a public IP**, after IAM propagation:

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64' \
  --query 'Parameter.Value' --output text --region "$AWS_REGION")

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table --region "$AWS_REGION"

export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces "DeviceIndex=0,SubnetId=$PRIVATE_SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --count 1 \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output json --region "$AWS_REGION"
```

**Expected:** `PublicIP` is `null`; the private IP is from `10.20.2.0/24`.

## 6 — Verify the working baseline

Check SSM online status and connect:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table --region "$AWS_REGION"

aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
```

The second command requires the Session Manager plugin. The AWS Console's Session Manager is an alternative.

**Inside EC2**, run:

```bash
ip -br addr
ip route
getent ahostsv4 example.com
curl -4 -I --connect-timeout 5 --max-time 10 https://example.com
curl -4 -fsS --connect-timeout 5 --max-time 10 https://checkip.amazonaws.com
```

In a **separate WSL2 terminal**, find the NAT public IPv4:

```bash
aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
  --output text --region "$AWS_REGION"
```

**Expected:** The EC2 egress IP reported by `checkip.amazonaws.com` matches the NAT Elastic IP. No EC2 public IPv4 is assigned. Exit the SSM session.

### Optional connectivity recorder

To capture a before/during/after timeline, start this on the instance **before** changing the route:

```bash
sudo systemd-run --unit=vpc-lab02-probe --collect \
  /bin/bash -c 'for i in $(seq 1 36); do
    printf "%s " "$(date -u +%FT%TZ)" >> /var/tmp/vpc-lab02-probe.log
    if /usr/bin/curl -4 -fsS --connect-timeout 2 --max-time 5 \
       https://example.com/ -o /dev/null; then
      echo HTTPS_OK >> /var/tmp/vpc-lab02-probe.log
    else
      echo HTTPS_FAILED >> /var/tmp/vpc-lab02-probe.log
    fi
    sleep 10
  done'

sudo tail /var/tmp/vpc-lab02-probe.log
exit
```

This is optional, runs for a limited number of iterations, and continues after the SSM shell disconnects.

## 7 — Intentionally reproduce the fault

**From WSL2, not the private instance**, verify the effective route table and its association first:

```bash
aws ec2 describe-route-tables --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].{Routes:Routes,Associations:Associations}' \
  --output json --region "$AWS_REGION"
```

**Only if this is the dedicated private subnet route table**, remove its default NAT route:

```bash
aws ec2 delete-route \
  --route-table-id "$PRIVATE_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --region "$AWS_REGION"

aws ec2 describe-route-tables --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes' --output table --region "$AWS_REGION"
```

**Expected route state:** Only the VPC-local route remains; the `0.0.0.0/0` route is absent. HTTPS and SSM traffic relying on NAT may fail. SSM's reported `Online` state can lag behind actual connectivity.

## 8 — Diagnose systematically

Use the AWS CLI from WSL2 to isolate the failure without depending on instance access:

```bash
# NAT gateway should still be available.
aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{State:State,Subnet:SubnetId,Addresses:NatGatewayAddresses}' \
  --output json --region "$AWS_REGION"

# Public route should still target IGW.
aws ec2 describe-route-tables --route-table-ids "$PUBLIC_RT_ID" \
  --query 'RouteTables[0].Routes' --output table --region "$AWS_REGION"

# Private route table should be missing the NAT default route.
aws ec2 describe-route-tables --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes' --output table --region "$AWS_REGION"

# Instance status checks may still be healthy.
aws ec2 describe-instance-status --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table --region "$AWS_REGION"

# SSM connection status (eventually consistent).
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table --region "$AWS_REGION"
```

### Root cause analysis

| Check | During fault |
|---|---|
| EC2 state | `running` |
| EC2 public IP | None, intentionally |
| NAT gateway | `available` |
| IGW | Attached |
| Public subnet route | `0.0.0.0/0 → IGW` |
| Private subnet route | **Missing `0.0.0.0/0 → NAT`** |
| HTTPS from EC2 | Expected to fail |
| SSM | May disconnect |

**Root cause:** Private subnet traffic destined outside the VPC has no default IPv4 route to the NAT gateway.

### Five Whys

1. Why did external API access fail? Private EC2 cannot route to internet destinations.
2. Why couldn't the traffic reach NAT? The default NAT route was removed.
3. Why was an available NAT gateway insufficient? NAT must be selected by the private subnet's effective route table.
4. Why did EC2 still pass status checks? Status checks do not validate every application path.
5. How do we prevent recurrence? Review and validate route table changes through infrastructure as code and controlled change management.

## 9 — Remediate and verify

From **WSL2**:

```bash
aws ec2 create-route \
  --route-table-id "$PRIVATE_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_ID" \
  --region "$AWS_REGION"

aws ec2 describe-route-tables --route-table-ids "$PRIVATE_RT_ID" \
  --query 'RouteTables[0].Routes' --output table --region "$AWS_REGION"
```

**Expected:** Default route now targets `nat-...`.

Reconnect with Session Manager when SSM reports `Online`, then run **inside EC2**:

```bash
sudo cat /var/tmp/vpc-lab02-probe.log  # Only if you started the optional recorder
getent ahostsv4 example.com
curl -4 -I --connect-timeout 5 --max-time 10 https://example.com
curl -4 -fsS --connect-timeout 5 --max-time 10 https://checkip.amazonaws.com
```

The last response should match the NAT Elastic IP, barring other egress/proxy configuration. Do not invent results: include your observed status and screenshots in this README after running the commands.

### Verification matrix

| Check | Before fault | During fault | After fix |
|---|---|---|---|
| EC2 state | Running | Running | Running |
| EC2 public IPv4 | None | None | None |
| NAT | Available | Available | Available |
| Public route to IGW | Present | Present | Present |
| Private route to NAT | Present | **Missing** | Restored |
| HTTPS | Successful | Failed | Successful |
| SSM | Online | May disconnect | Online |

## 10 — Cleanup: delete cost-bearing resources

**Verify project tags and AWS identity first.** These commands assume the resources were created solely for Lab 02. NAT gateway deletion can take time. Do not delete default VPC, shared route tables, or unrelated assets.

```bash
aws sts get-caller-identity
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{ID:VpcId,Tags:Tags}' --output json --region "$AWS_REGION"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,Tags:Tags}' \
  --output json --region "$AWS_REGION"

# Save root EBS ID and verify DeleteOnTermination.
export ROOT_VOLUME_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text --region "$AWS_REGION")
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text --region "$AWS_REGION"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Check NAT tags before deleting.
aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].{ID:NatGatewayId,State:State,Tags:Tags}' \
  --output json --region "$AWS_REGION"
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$AWS_REGION"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"

# Verify EIP is detached before releasing.
aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" \
  --output json --region "$AWS_REGION"
aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$AWS_REGION"
```

Remove IAM resources after confirming no unrelated instance uses the profile:

```bash
aws iam list-role-tags --role-name "$ROLE_NAME"
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
aws iam delete-role --role-name "$ROLE_NAME"
```

Remove network resources in dependency order:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$AWS_REGION"
# Only if no interfaces use it:
aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"

aws ec2 disassociate-route-table --association-id "$PRIVATE_ASSOC_ID" --region "$AWS_REGION"
aws ec2 disassociate-route-table --association-id "$PUBLIC_ASSOC_ID" --region "$AWS_REGION"
aws ec2 delete-route-table --route-table-id "$PRIVATE_RT_ID" --region "$AWS_REGION"
aws ec2 delete-route-table --route-table-id "$PUBLIC_RT_ID" --region "$AWS_REGION"
aws ec2 delete-subnet --subnet-id "$PRIVATE_SUBNET_ID" --region "$AWS_REGION"
aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_ID" --region "$AWS_REGION"
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" --region "$AWS_REGION"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"

aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output table --region "$AWS_REGION"
# Delete only once no dependent resources remain:
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION"

# A NotFound response indicates root EBS auto-deletion completed.
aws ec2 describe-volumes --volume-ids "$ROOT_VOLUME_ID" --region "$AWS_REGION"
```

### Cost cleanup checklist

- [ ] EC2 terminated and EBS root volume removed
- [ ] NAT gateway deleted
- [ ] NAT Elastic IP released
- [ ] Instance profile and IAM role deleted
- [ ] Lab security group removed
- [ ] Lab route tables and subnets removed
- [ ] IGW detached and deleted
- [ ] Dedicated lab VPC deleted
- [ ] No unrelated resources changed

## 11 — Production recommendations

- Use one NAT gateway per AZ for resilient multi-AZ internet egress where requirements justify it; route each private subnet to its AZ-local NAT gateway.
- Prefer VPC endpoints for supported AWS services when appropriate to reduce dependence on public NAT egress.
- Manage subnet and route-table configuration through Terraform or CloudFormation and peer-reviewed changes.
- Verify route table associations, NAT health, SG egress, NACL return traffic, and DNS when diagnosing failures.
- Preserve an independent remediation path before intentionally interrupting networking.
- Monitor NAT gateway usage, failures, availability, and costs.

## 12 — Interview questions

**Q1. Why does a private EC2 instance need a NAT gateway for outbound IPv4 internet access?**  
A public NAT gateway enables outbound connections through an IGW without assigning the private instance a public IPv4 address. Other egress architectures are possible depending on requirements.

**Q2. Where should a public NAT gateway be placed?**  
In a public subnet with an attached internet gateway route and associated Elastic IP.

**Q3. Which private-subnet route is required?**  
`0.0.0.0/0 → nat-...` in the subnet's associated route table.

**Q4. Why might SSM Session Manager disconnect when the NAT route disappears?**  
The SSM Agent may rely on NAT for outbound HTTPS connectivity to Systems Manager endpoints if no suitable interface endpoints exist.

**Q5. Why might EC2 status checks still pass?**  
They assess instance and AWS host health rather than successful access to every internet destination.

**Q6. What is the difference between a NAT gateway and an internet gateway?**  
An internet gateway connects a VPC to the internet for appropriately addressed and routed resources; a public NAT gateway provides translated outbound IPv4 connectivity for private resources.

**Q7. How would you describe this incident in an interview?**  
> I created an isolated AWS VPC with public and private subnets. A public NAT gateway provided egress for an EC2 instance without a public IP. After verifying HTTPS and the NAT egress IP, I deliberately removed the private route table's default route. I diagnosed the issue by comparing public and private route tables, NAT state, and EC2 health. I restored the NAT route, verified connectivity, and deleted all cost-bearing resources.

## 13 — Skills demonstrated

Amazon VPC, public/private subnet design, internet gateways, NAT gateways, Elastic IPs, route-table troubleshooting, IAM instance profiles, SSM Session Manager, Linux networking diagnostics, AWS CLI, fault injection, incident analysis, remediation, validation, and resource cleanup.

## Repository files

```text
02-private-subnet-internet-failure/
├── README.md
└── ec2-trust-policy.json
```

`ec2-trust-policy.json` is an **IAM assume-role trust policy**, not the SSM permissions policy. The managed `AmazonSSMManagedInstanceCore` policy provides those permissions.

## References

- [AWS — NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
- [AWS — Subnet route tables](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-route-tables.html)
- [AWS — Session Manager prerequisites](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-prerequisites.html)

---

**Expected outcome:** Private subnet HTTPS connectivity is restored by correcting the missing NAT default route while the EC2 instance remains without a public IPv4 address. Record actual observations before reporting a completed hands-on test.
