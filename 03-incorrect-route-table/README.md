# Lab 03 — Amazon VPC Incorrect Route Table

## Overview

This lab demonstrates how to troubleshoot an Amazon EC2 instance that loses internet connectivity because its subnet is associated with an incorrect VPC route table.

The VPC contains two custom route tables. The correct public route table has a default route to the internet gateway, while the incorrect route table contains only the VPC-local route.

We first verify that the EC2 instance can access the internet. Then we intentionally change the subnet's route table association, investigate the connectivity failure, restore the correct association, and verify recovery.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce Misconfiguration → Diagnose → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-003 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Linux networking tools |
| VPC CIDR | `10.30.0.0/16` |
| Subnet CIDR | `10.30.1.0/24` |
| Correct Route Table | Default route to internet gateway |
| Incorrect Route Table | VPC-local route only |
| Simulated Fault | Subnet associated with incorrect route table |
| Root Cause | Wrong route table association |
| Remediation | Replace association with correct route table |
| Expected Result | HTTPS connectivity restored |

---

## 1. Production Incident Scenario

### Incident Description

A cloud engineering team manages an application hosted on an Amazon EC2 instance in a public subnet.

After a networking configuration change, the application cannot connect to external APIs.

The instance is still running and has a public IPv4 address.

Initial investigation confirms that the internet gateway is attached and that the correct public route table exists.

However, the subnet is associated with another route table that does not contain a default internet route.

### Expected Behavior

The EC2 instance should have outbound internet connectivity through:

```text
Public EC2 → Public Subnet → Correct Route Table → Internet Gateway → Internet
```

The correct route table should include:

```text
Destination       Target
10.30.0.0/16      local
0.0.0.0/0         igw-xxxxxxxx
```

### Actual Misconfiguration

The subnet uses an incorrect route table containing:

```text
Destination       Target
10.30.0.0/16      local
```

The correct route table still exists, but it is not associated with the subnet.

### Potential Business Impact

- External API requests fail
- Application integrations become unavailable
- Package downloads and deployment processes fail
- Systems Manager connectivity may be interrupted
- Production troubleshooting time increases
- Network changes can cause unintended service downtime

### Investigation Objective

Identify which route table is actually associated with the subnet, explain why outbound traffic fails, and restore the intended public routing configuration.

---

## 2. AWS Architecture

### Healthy Architecture

```text
                         Internet
                            |
                     Internet Gateway
                            |
                  +--------------------+
                  | AWS VPC            |
                  | 10.30.0.0/16       |
                  |                    |
                  | Correct Route Table|
                  | 10.30.0.0/16 local |
                  | 0.0.0.0/0 → IGW    |
                  |          |         |
                  |          v         |
                  | Public Subnet      |
                  | 10.30.1.0/24       |
                  |          |         |
                  |          v         |
                  | EC2 + Public IPv4  |
                  +--------------------+
```

### Broken Architecture

```text
                         Internet
                            |
                     Internet Gateway
                            |
                 Correct Route Table
                   0.0.0.0/0 → IGW
                            |
                       NOT USED

                 +--------------------+
                 | AWS VPC            |
                 | 10.30.0.0/16       |
                 |                    |
                 | Incorrect Route    |
                 | Table              |
                 | 10.30.0.0/16 local |
                 | NO DEFAULT ROUTE   |
                 |          |         |
                 |          v         |
                 | Public Subnet      |
                 | 10.30.1.0/24       |
                 |          |         |
                 |          v         |
                 | EC2 + Public IPv4  |
                 | INTERNET FAILED    |
                 +--------------------+
```

### Corrected Architecture

```text
Subnet Association:
Incorrect Route Table → Correct Route Table

Effective Routes:
10.30.0.0/16 → local
0.0.0.0/0    → Internet Gateway
```

**Important:** The issue is an incorrect route table association, not a deleted route entry.

---

## 3. Understanding Route Tables

A VPC route table contains routes that control where subnet traffic is directed.

Each subnet uses one effective route table.

A subnet can use either:

- The VPC's main route table, through implicit association.
- A custom route table, through explicit association.

### Correct vs. Incorrect Route Table

| Feature | Correct Route Table | Incorrect Route Table |
|---|---|---|
| VPC-local route | Present | Present |
| Default internet route | Present | Missing |
| Route to internet gateway | Yes | No |
| Intended for public subnet | Yes | No |
| Internet connectivity | Possible | Unavailable through IGW |

### Important AWS CLI Operations

| Command | Purpose |
|---|---|
| `create-route-table` | Create a route table |
| `create-route` | Add a route |
| `associate-route-table` | Associate a subnet with a route table |
| `describe-route-tables` | Inspect routes and associations |
| `replace-route-table-association` | Change the associated route table |
| `disassociate-route-table` | Remove an explicit association |

The `replace-route-table-association` operation returns a new association ID, which must be retained for subsequent operations.

---

## 4. Prerequisites and Safety

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Git
- Permissions to manage dedicated VPC networking resources
- EC2 launch permissions
- IAM role and instance profile management permissions
- Systems Manager Session Manager access

### Safety Requirements

- Create a dedicated VPC.
- Do not modify the default VPC.
- Do not affect shared route tables.
- Use a dedicated EC2 instance.
- Do not open inbound SSH access.
- Verify the subnet association before modifying it.
- Restore routing from the local AWS CLI if Session Manager disconnects.
- Verify tags before deleting resources.

### Cost Considerations

The lab may incur EC2 compute, EBS, public IPv4, and data transfer charges.

No NAT gateway or paid interface endpoint is necessary.

---

## 5. Prepare the Environment

Run all AWS CLI commands in Ubuntu WSL2 unless stated otherwise.

### Step 1 — Create Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab03"

export VPC_NAME="cloud-lab03-vpc"
export SUBNET_NAME="cloud-lab03-public-subnet"
export IGW_NAME="cloud-lab03-igw"

export GOOD_RT_NAME="cloud-lab03-correct-rt"
export BAD_RT_NAME="cloud-lab03-incorrect-rt"

export SG_NAME="cloud-lab03-sg"
export INSTANCE_NAME="cloud-lab03-ec2"

export ROLE_NAME="cloud-lab03-ssm-role"
export PROFILE_NAME="cloud-lab03-ssm-profile"

export VPC_CIDR="10.30.0.0/16"
export SUBNET_CIDR="10.30.1.0/24"
```

Verify account:

```bash
aws sts get-caller-identity
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

Choose one of the listed Availability Zones:

```bash
export LAB_AZ="us-east-1a"
```

Replace the example if necessary.

---

## 6. Create the Dedicated VPC

### Step 1 — Check for Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate if a lab VPC already exists.

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

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

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

### Step 2 — Enable Automatic Public IPv4 Assignment

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 3 — Verify Subnet

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `PublicIP=True`.

---

## 8. Create the Internet Gateway

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Attach Internet Gateway

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Verify Attachment

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the internet gateway is attached to the dedicated VPC.

---

## 9. Create Correct and Incorrect Route Tables

### Step 1 — Create the Correct Route Table

```bash
export GOOD_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=$GOOD_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Add the Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$GOOD_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Create the Incorrect Route Table

```bash
export BAD_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=$BAD_RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Do not add an internet route to the incorrect table.

### Step 4 — Compare Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$GOOD_RT_ID" "$BAD_RT_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Correct Route Table:
10.30.0.0/16 → local
0.0.0.0/0    → igw-...

Incorrect Route Table:
10.30.0.0/16 → local
```

### Step 5 — Associate the Correct Table

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$GOOD_RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

The subnet should initially use the correct route table.

---

## 10. Create the Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab03 incorrect route table investigation" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Verify the group:

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

- No inbound rules.
- Outbound traffic allowed under the new group's default egress rules.

---

## 11. Configure IAM for Systems Manager

### Step 1 — Create the EC2 Trust Policy

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

Create it using WSL2:

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

### Step 2 — Create IAM Role

Verify the role name is not already in use.

```bash
aws iam get-role --role-name "$ROLE_NAME"
```

Then create if absent:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach SSM Permissions

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

### Step 5 — Associate Role With Instance Profile

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

Allow time for IAM propagation.

---

## 12. Launch the EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for an Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

If an instance exists, investigate and reuse it instead of launching a duplicate.

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

### Step 5 — Verify Instance Networking

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,Subnet:SubnetId}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: instance running with a public IPv4 address.

---

## 13. Establish a Healthy Connectivity Baseline

### Step 1 — Check Session Manager Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after agent registration: `Online`.

### Step 2 — Connect to the Instance

Use EC2 Console → Instances → Connect → Session Manager.

Or use the AWS CLI with the Session Manager plugin installed:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Networking

Inside EC2:

```bash
ip route
getent ahostsv4 example.com
```

### Step 4 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

### Step 5 — Start Connectivity Probe

This temporary probe collects evidence of connectivity before, during, and after the route table association failure.

```bash
sudo systemd-run \
  --unit=vpc-lab03-probe \
  --collect \
  /bin/bash -c 'for i in $(seq 1 48); do
    printf "%s " "$(date -u +%FT%TZ)" >> /var/tmp/vpc-lab03-probe.log
    if /usr/bin/curl -4 -fsS \
       --connect-timeout 2 --max-time 5 \
       https://example.com/ -o /dev/null; then
      echo HTTPS_OK >> /var/tmp/vpc-lab03-probe.log
    else
      echo HTTPS_FAILED >> /var/tmp/vpc-lab03-probe.log
    fi
    sleep 10
  done'
```

Verify:

```bash
sudo tail /var/tmp/vpc-lab03-probe.log
```

Expected: `HTTPS_OK`.

Exit Session Manager:

```bash
exit
```

---

## 14. Reproduce the Incorrect Route Table Association

### Step 1 — Verify the Original Association

From WSL2:

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the subnet is associated with `$GOOD_RT_ID`.

### Step 2 — Introduce the Misconfiguration

```bash
export RT_ASSOC_ID=$(aws ec2 replace-route-table-association \
  --association-id "$RT_ASSOC_ID" \
  --route-table-id "$BAD_RT_ID" \
  --query NewAssociationId \
  --output text \
  --region "$AWS_REGION")
```

This changes the subnet's associated route table.

**Important:** The API returns a new association ID. Save the new ID for remediation.

### Step 3 — Verify the Wrong Association

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
RouteTableId: <BAD_RT_ID>

10.30.0.0/16 → local
```

The default internet route is absent from the effective route table.

### Expected Failure

The instance cannot use the internet gateway for internet-bound IPv4 traffic.

Systems Manager may also lose its outbound connection to AWS service endpoints.

EC2 system and instance status checks can remain healthy.

---

## 15. Troubleshooting Investigation

### Check 1 — Confirm the Correct Route Table Still Exists

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$GOOD_RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `0.0.0.0/0 → IGW` is still present.

### Check 2 — Inspect Internet Gateway

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Expected: IGW attached.

### Check 3 — Inspect Public IPv4

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,PublicIP:PublicIpAddress,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: EC2 running and public IPv4 assigned.

### Check 4 — Inspect Security Group Egress

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound traffic permitted.

### Check 5 — Inspect Network ACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkAcls[].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the lab VPC's default NACL has not been restricted.

### Check 6 — Inspect the Effective Subnet Association

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: subnet uses `$BAD_RT_ID`.

### Investigation Summary

| Component | Finding |
|---|---|
| EC2 | Running |
| Public IPv4 | Assigned |
| IGW | Attached |
| Correct route table | Contains internet route |
| Incorrect route table | Local route only |
| Security group | Outbound allowed |
| Network ACL | Default configuration |
| Effective subnet association | Incorrect |
| Root cause | Wrong route table association |

---

## 16. Root Cause Analysis

### Root Cause

The subnet was explicitly associated with a route table that did not provide a default internet route.

### Technical Explanation

AWS evaluates the routes in the route table effectively associated with the subnet.

Although the correct route table contained a valid internet route, those routes were not used by the instance's subnet after the association was replaced.

The failure was caused by a control-plane configuration change.

### Root Cause Flow

```text
EC2 Outbound HTTPS Request
            |
            v
       Public Subnet
            |
            v
    Effective Route Table
            |
            v
      Incorrect Route Table
            |
            v
       Local Route Only
            |
            X
   No Route to Internet
```

### Five Whys

1. **Why did outbound traffic fail?** The subnet had no effective internet route.
2. **Why was the route unavailable?** The subnet was associated with the wrong table.
3. **Why wasn't the correct table sufficient?** Its routes were not being used by that subnet.
4. **Why did the EC2 instance remain running?** The change affected VPC routing, not guest operating-system availability.
5. **How can recurrence be prevented?** Manage route table associations through reviewed infrastructure as code and validate effective subnet routing.

---

## 17. Remediation

### Step 1 — Restore the Correct Association

From WSL2:

```bash
export RT_ASSOC_ID=$(aws ec2 replace-route-table-association \
  --association-id "$RT_ASSOC_ID" \
  --route-table-id "$GOOD_RT_ID" \
  --query NewAssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Verify Correct Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
RouteTableId: <GOOD_RT_ID>

10.30.0.0/16 → local
0.0.0.0/0    → igw-xxxxxxxx
```

### Step 3 — Verify Systems Manager Connectivity

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after reconnection: `Online`.

### Step 4 — Review Connectivity Logs

Reconnect using Session Manager:

```bash
sudo cat /var/tmp/vpc-lab03-probe.log
```

Look for observations showing:

```text
HTTPS_OK
HTTPS_FAILED
HTTPS_FAILED
HTTPS_OK
```

The exact sequence depends on the timing of the routing change.

These entries are illustrative; use actual outputs as evidence of the experiment.

### Step 5 — Test HTTPS Again

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: an HTTP response.

### Step 6 — Verify DNS

```bash
getent ahostsv4 example.com
```

Expected: IPv4 addresses returned.

Exit Session Manager:

```bash
exit
```

---

## 18. Verification Matrix

| Check | Healthy Baseline | Failure | After Fix |
|---|---|---|---|
| EC2 running | Yes | Yes | Yes |
| Public IPv4 | Present | Present | Present |
| IGW attached | Yes | Yes | Yes |
| Correct RT contains internet route | Yes | Yes | Yes |
| Subnet uses correct RT | Yes | No | Yes |
| Effective default route | Present | Missing | Restored |
| Outbound HTTPS | Successful | Failed | Successful |
| Session Manager | Online | May disconnect | Online |
| Root cause | None | Wrong association | Corrected |

### Success Criteria

The incident is resolved when:

- The subnet is associated with the correct route table.
- The effective table has a default route to the IGW.
- The EC2 instance retains its public IPv4.
- DNS resolution works.
- HTTPS connectivity succeeds.
- Systems Manager access is restored.
- The application-level connectivity probe shows the expected recovery behavior, if observations were captured.

---

## 19. Production Engineering Best Practices

### Common Route Table Errors

| Problem | Possible Impact |
|---|---|
| Wrong subnet association | Traffic follows unintended route table |
| Missing default route | No internet path |
| Wrong gateway target | Traffic routed incorrectly |
| Missing VPC peering route | Cross-VPC connectivity fails |
| Incorrect NAT target | Private subnet egress fails |
| Blackhole route | Traffic cannot reach route target |
| Unexpected main route table fallback | Subnet traffic behavior changes |

### Recommended Troubleshooting Method

1. Identify the affected instance and subnet.
2. Find the subnet's effective route table.
3. Inspect destinations and next-hop targets.
4. Compare the effective table with the intended table.
5. Verify gateway or NAT target availability.
6. Inspect security groups and network ACLs.
7. Reproduce or review the application failure.
8. Correct the minimum necessary configuration.
9. Verify application connectivity.
10. Document the incident and prevention measures.

### Prevention

- Define route table associations using Terraform or CloudFormation.
- Review networking changes through pull requests.
- Tag subnets and route tables consistently.
- Avoid relying on the VPC main route table for unrelated workloads.
- Check effective subnet routing after infrastructure changes.
- Use Reachability Analyzer when appropriate.
- Monitor application connectivity, not only EC2 status checks.
- Keep a recovery management path available when performing network changes.

---

## 20. Interview Questions and Answers

### Q1. What is an AWS VPC route table?

A route table is a collection of routes that determines where subnet traffic is directed.

### Q2. What is the difference between a missing route and an incorrect route table association?

A missing route is an absent entry in the active route table. An incorrect association means the subnet uses a different table, even if the correct route exists elsewhere.

### Q3. How many effective route tables can a subnet use?

One at a time, either explicitly through a custom association or implicitly through the VPC main route table.

### Q4. What is the main route table?

It is the route table used by subnets that have no explicit custom route table association.

### Q5. What does `replace-route-table-association` do?

It replaces an existing route table association and returns a new association ID.

### Q6. Does an attached internet gateway guarantee internet access?

No. The subnet must use a route table with the required route, and EC2 networking and security settings must permit connectivity.

### Q7. Why can an EC2 instance be healthy while internet access fails?

EC2 status checks do not test every application network path.

### Q8. What happens when you disassociate a custom route table?

The subnet falls back to the VPC's main route table unless another explicit association is established.

### Q9. How do you check which route table a subnet uses?

Inspect the subnet's explicit association using `describe-route-tables`; if none exists, identify the main route table for the VPC.

### Q10. Why is route table association important for cloud security?

Associations determine which network routes apply to each subnet. An incorrect association can expose resources to unwanted paths or block required communication.

### Q11. What is a blackhole route?

A route whose target is unavailable, causing traffic that matches the route to fail.

### Q12. How would you describe this lab in an interview?

> I created an isolated AWS VPC with a public subnet, an internet gateway, and two route tables. The correct table had a default route to the internet, while the incorrect table only had the local VPC route. After verifying EC2 connectivity, I deliberately changed the subnet association to the incorrect table and investigated the failure using AWS CLI. I found that the required route still existed in another table, but the subnet was not associated with it. I restored the correct association and verified HTTPS and Session Manager connectivity.

---

## 21. Cleanup

**Warning:** Confirm the AWS account and resource tags before deleting anything. All commands below are for the dedicated Lab 03 resources.

### Step 1 — Verify AWS Account and VPC

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `Project=VPC-Troubleshooting-Lab03`.

### Step 2 — Verify Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check `DeleteOnTermination`:

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
aws iam list-role-tags --role-name "$ROLE_NAME"
```

Confirm this role belongs exclusively to Lab 03 and its instance profile is not used by another active instance.

### Step 6 — Delete IAM Role and Instance Profile

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

### Step 7 — Delete Security Group

Check dependencies:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

When no network interfaces depend on the group:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Verify Current Route Table Association

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].Associations[].{ID:RouteTableAssociationId,Subnet:SubnetId}' \
  --output table \
  --region "$AWS_REGION"
```

Use the current association ID returned by the last replacement.

### Step 9 — Disassociate Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Custom Route Tables

```bash
aws ec2 delete-route-table \
  --route-table-id "$GOOD_RT_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$BAD_RT_ID" \
  --region "$AWS_REGION"
```

Do not manually delete the main route table.

### Step 11 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Detach Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Internet Gateway

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Verify VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Ensure no remaining instances, interfaces, subnets, or other resources depend on the VPC.

### Step 15 — Delete Dedicated VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Verify Root EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

An `InvalidVolume.NotFound` response indicates the volume no longer exists.

If it remains, verify its ownership and attachment status before deletion.

### Cleanup Summary

| Resource | Expected Outcome |
|---|---|
| EC2 instance | Terminated |
| Root EBS | Removed |
| Security group | Deleted |
| SSM IAM role | Deleted |
| Instance profile | Deleted |
| Correct route table | Deleted |
| Incorrect route table | Deleted |
| Public subnet | Deleted |
| Internet gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 22. Repository Structure

```text
03-incorrect-route-table/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Incident report, setup, fault simulation, troubleshooting, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | EC2 IAM role trust relationship used for Session Manager |

Do not commit AWS credentials, private keys, or confidential account information.

---

## 23. Lessons Learned

This lab demonstrated how EC2 internet connectivity can fail even when the correct internet route and internet gateway exist.

The failure occurred because the subnet was associated with an incorrect route table that contained only its local VPC route.

The investigation showed why cloud engineers must identify the **effective route table associated with the subnet**, rather than simply locating a route table containing the desired route.

After restoring the correct association, internet connectivity could be verified again from the EC2 instance.

The lab also introduced an important operational consideration: network changes can interrupt remote management access, so remediation should remain available through an independent AWS control-plane connection.

**Key Lesson:** When troubleshooting AWS VPC routing, inspect both the route entries and the route table associations.

---

## 24. Skills Demonstrated

- Amazon VPC routing
- Public subnet networking
- Route table association troubleshooting
- Internet gateway configuration
- AWS CLI diagnostics
- `replace-route-table-association`
- EC2 network connectivity verification
- Security group inspection
- Network ACL inspection
- IAM roles and instance profiles
- AWS Systems Manager Session Manager
- Linux networking tools
- Controlled networking failure simulation
- Root cause analysis
- Incident remediation
- Infrastructure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-003 |
| Problem | EC2 internet access fails |
| Root Cause | Incorrect subnet route table association |
| Correct Route | `0.0.0.0/0 → IGW` |
| Fault Introduced | Subnet associated with wrong table |
| Remediation | Restore correct association |
| EC2 State | Running |
| Internet Connectivity | Restored |
| SSM Connectivity | Restored |
| Cleanup | Dedicated resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** A correct route table does not help a subnet unless that subnet is actually using it. Always verify the effective subnet association, restore the intended routing configuration, and confirm application connectivity afterward.
