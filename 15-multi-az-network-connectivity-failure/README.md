# Lab 15 — Multi-AZ Network Connectivity Failure

## Overview

This lab demonstrates how to investigate and resolve a network connectivity failure between two Amazon EC2 instances deployed in different AWS Availability Zones.

We create a VPC with two subnets in separate Availability Zones. The first EC2 instance acts as an HTTP client, while the second runs a Python HTTP server on TCP port 8080.

Initially, both instances communicate successfully using private IPv4 addresses through the VPC's local route.

We intentionally introduce a high-priority deny rule in the Network Access Control List (NACL) associated with the server subnet.

Although the EC2 instances, route tables, and security groups remain correctly configured, the client can no longer reach the server.

We investigate the failure, identify the blocking NACL rule, restore the required connectivity, verify the application, and clean up the AWS resources.

**Troubleshooting workflow:**

Provision → Establish Baseline → Inject Failure → Investigate → Identify Root Cause → Remediate → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-015 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Python |
| VPC CIDR | `10.150.0.0/16` |
| AZ A Subnet | `10.150.1.0/24` |
| AZ B Subnet | `10.150.2.0/24` |
| Availability Zones | Two distinct supported AZs |
| Client | EC2 in AZ A |
| Server | EC2 in AZ B |
| Application | Python HTTP server |
| Destination Port | TCP 8080 |
| Security Group | Allows client-to-server HTTP |
| Fault Injection | Inbound NACL rule 90 — DENY |
| Root Cause | High-priority NACL rule blocking TCP 8080 |
| Remediation | Remove the deny rule |
| Verification | HTTP 200 and connectivity logs |

---

## 2. Production Incident Scenario

### Incident Description

A company deploys its applications across multiple AWS Availability Zones to improve availability.

The application architecture contains a client service in Availability Zone A and a backend service in Availability Zone B.

Both workloads run inside the same VPC and communicate using private IP addresses.

Following a network security configuration change, the application can no longer communicate with the backend service.

The cloud engineer investigates and discovers:

- Both EC2 instances are running.
- Both Availability Zones are operational.
- The VPC local route is present.
- The client security group allows outbound connections.
- The server security group allows inbound TCP 8080.
- The server application is running.
- A custom NACL is associated with the AZ B subnet.
- Inbound NACL rule 90 denies TCP 8080 from the AZ A subnet.
- Lower-priority rule 100 allows traffic, but rule 90 matches first.
- HTTP requests from AZ A to AZ B time out.

### Expected Behavior

```text
Client EC2 — AZ A
        |
        v
VPC Local Route
        |
        v
AZ B Subnet NACL
        |
        v
Server Security Group
        |
        v
HTTP Server — TCP 8080
        |
        v
HTTP 200 OK
```

### Failure Behavior

```text
Client EC2 — AZ A
        |
        v
VPC Local Route
        |
        v
AZ B Subnet NACL
        |
        X
Rule 90 — DENY TCP 8080
        |
        X
Server Unreachable
```

### Potential Business Impact

- Internal applications experience connection timeouts.
- Backend APIs become unavailable.
- Cross-AZ microservice communication fails.
- Application requests may fail.
- Service performance decreases.
- Troubleshooting takes additional engineering time.
- Multi-AZ deployment does not deliver its intended resilience.

### Incident Objective

Identify the subnet-level network security rule blocking communication between two Availability Zones and restore private application connectivity without unnecessarily changing the VPC routes or security groups.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                    AWS Region: us-east-1

             +--------------------------------------+
             | VPC: 10.150.0.0/16                   |
             |                                      |
             | +----------------+ +---------------+ |
             | | AZ A           | | AZ B          | |
             | |                | |               | |
             | | Subnet A       | | Subnet B      | |
             | | 10.150.1.0/24  | | 10.150.2.0/24 | |
             | |                | |               | |
             | | Client EC2     | | Server EC2    | |
             | |                | | TCP 8080      | |
             | | Client SG      | | Server SG     | |
             | |                | |               | |
             | | Default NACL   | | Custom NACL   | |
             | +--------+-------+ +-------+-------+ |
             |          |                 |         |
             |          +---- Local ------+         |
             |               Routing                |
             +--------------------------------------+

                    HTTP Communication
                         Successful
```

### Broken Architecture

```text
Availability Zone A             Availability Zone B

Client EC2                       Server EC2
    |                                ^
    |                                |
    v                                |
Local VPC Route                     |
    |                                |
    +-------- TCP 8080 -------------> X
                                     |
                              Custom NACL
                                     |
                              Rule 90: DENY
                                     |
                              Request Blocked
```

### AWS Resources

| Component | AZ A | AZ B |
|---|---|---|
| VPC | Same VPC | Same VPC |
| Subnet | `10.150.1.0/24` | `10.150.2.0/24` |
| EC2 workload | Client | HTTP server |
| Instance type | `t3.micro` | `t3.micro` |
| Security group | Client SG | Server SG |
| NACL | Default | Custom |
| Management | Systems Manager | Systems Manager |
| Application port | Outbound TCP 8080 | Inbound TCP 8080 |

Both EC2 instances have public internet routes for Systems Manager management, but the tested application traffic uses private IP addresses.

The Internet Gateway is not used for cross-AZ application communication.

---

## 4. Understanding Multi-AZ Networking

An AWS Availability Zone is an isolated location within an AWS Region.

Deploying applications across multiple Availability Zones can improve resilience against failures affecting one Availability Zone.

### Important Networking Concepts

1. A subnet belongs to one Availability Zone.
2. A VPC can contain subnets across multiple Availability Zones within its Region.
3. Subnets in the same VPC can communicate using the VPC-local route.
4. VPC peering is not required for communication between AZs in the same VPC.
5. Security groups and NACLs can restrict traffic between subnets.
6. Cross-AZ traffic may incur regional data transfer charges.

### Local VPC Routing

```text
Destination         Target
10.150.0.0/16       local
0.0.0.0/0           Internet Gateway
```

The local route allows communication between IP addresses inside the VPC, subject to security controls.

---

## 5. Understanding Network ACLs

A Network Access Control List is a subnet-level networking security control.

NACLs are stateless and contain numbered allow and deny rules.

### Security Group vs. Network ACL

| Feature | Security Group | Network ACL |
|---|---|---|
| Applied to | Network interface | Subnet |
| Stateful | Yes | No |
| Allow rules | Yes | Yes |
| Deny rules | No | Yes |
| Rule evaluation | Combined allow rules | Lowest rule number first |
| Return traffic | Automatically permitted for allowed connections | Must be explicitly permitted |
| Default behavior | Depends on configured rules | Depends on NACL type and rules |

### NACL Rule Priority

AWS evaluates NACL entries in ascending rule-number order.

The first matching rule determines whether traffic is allowed or denied.

### Healthy NACL

```text
Inbound Rules

Rule 100   ALLOW ALL   0.0.0.0/0
Rule *     DENY ALL    0.0.0.0/0

Outbound Rules

Rule 100   ALLOW ALL   0.0.0.0/0
Rule *     DENY ALL    0.0.0.0/0
```

### Broken NACL

```text
Inbound Rules

Rule 90    DENY TCP 8080   10.150.1.0/24
Rule 100   ALLOW ALL       0.0.0.0/0
Rule *     DENY ALL        0.0.0.0/0
```

Rule 90 matches the client's HTTP traffic before rule 100.

Therefore, the NACL blocks the request.

---

## 6. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC management permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated test VPC.
- Select two distinct Availability Zones.
- Keep inbound SSH rules closed.
- Do not modify shared or production NACLs.
- Verify security groups before injecting the fault.
- Use private IP addresses for application tests.
- Verify resource tags before cleanup.
- Remove temporary resources after completion.

### Cost Considerations

Possible charges include:

- Two EC2 instances
- EBS root volumes
- Public IPv4 addresses
- Applicable cross-AZ data transfer
- Other applicable network usage

Delete the resources after finishing the lab.

---

## 7. Prepare the AWS Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab15"

export VPC_CIDR="10.150.0.0/16"
export SUBNET_A_CIDR="10.150.1.0/24"
export SUBNET_B_CIDR="10.150.2.0/24"

export VPC_NAME="cloud-lab15-vpc"

export CLIENT_SG_NAME="cloud-lab15-client-sg"
export SERVER_SG_NAME="cloud-lab15-server-sg"

export ROLE_NAME="cloud-lab15-ssm-role"
export PROFILE_NAME="cloud-lab15-ssm-profile"
```

### Step 2 — Verify Credentials

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Select Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose two supported AZs:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

Verify that both AZ names appear in the results for your account.

### Step 4 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Inspect any existing Lab 15 resources before creating duplicates.

---

## 8. Create the VPC and Subnets

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

### Step 3 — Create Subnet A

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab15-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Subnet B

```bash
export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab15-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Enable Public IP Assignment

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_A_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"

aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_B_ID" \
  --map-public-ip-on-launch \
  --region "$AWS_REGION"
```

### Step 6 — Verify Availability Zones

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the two subnets are in different Availability Zones.

---

## 9. Configure Internet Gateway and Routing

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-lab15-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Create Shared Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab15-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Associate Subnet A

```bash
export RT_ASSOC_A=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_A_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Associate Subnet B

```bash
export RT_ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Verify Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.150.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

The local route supports communication between the two AZs.

---

## 10. Create Security Groups

### Step 1 — Create Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab15 AZ A client security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Server Security Group

```bash
export SERVER_SG_ID=$(aws ec2 create-security-group \
  --group-name "$SERVER_SG_NAME" \
  --description "Lab15 AZ B server security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SERVER_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow TCP 8080 from Client SG

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" "$SERVER_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

### Security Group Configuration

| Security Group | Inbound | Outbound |
|---|---|---|
| Client SG | No inbound rules | Default allow |
| Server SG | TCP 8080 from Client SG | Default allow |

The security groups are correctly configured throughout the experiment.

---

## 11. Configure the Custom Network ACL

### Step 1 — Identify Default NACL

```bash
export DEFAULT_NACL_ID=$(aws ec2 describe-network-acls \
  --filters \
  "Name=vpc-id,Values=$VPC_ID" \
  "Name=default,Values=true" \
  --query 'NetworkAcls[0].NetworkAclId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Custom NACL

```bash
export NACL_B_ID=$(aws ec2 create-network-acl \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=network-acl,Tags=[{Key=Name,Value=cloud-lab15-nacl-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NetworkAcl.NetworkAclId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow Inbound Traffic

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_B_ID" \
  --rule-number 100 \
  --protocol -1 \
  --rule-action allow \
  --cidr-block "0.0.0.0/0" \
  --ingress \
  --region "$AWS_REGION"
```

### Step 4 — Allow Outbound Traffic

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_B_ID" \
  --rule-number 100 \
  --protocol -1 \
  --rule-action allow \
  --cidr-block "0.0.0.0/0" \
  --egress \
  --region "$AWS_REGION"
```

These broad allow rules are used for fault isolation in the temporary lab.

### Step 5 — Identify Existing Subnet B Association

```bash
export OLD_NACL_ASSOC_B=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_B_ID" \
  --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Associate Custom NACL with AZ B

```bash
export NACL_ASSOC_B=$(aws ec2 replace-network-acl-association \
  --association-id "$OLD_NACL_ASSOC_B" \
  --network-acl-id "$NACL_B_ID" \
  --query NewAssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Verify NACL

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].{Associations:Associations,Rules:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Rule | Direction | Traffic | Action |
|---|---|---|---|
| 100 | Inbound | All IPv4 traffic | Allow |
| 100 | Outbound | All IPv4 traffic | Allow |
| * | Both | Remaining traffic | Deny |

---

## 12. Configure IAM and EC2

### Step 1 — Create EC2 Trust Policy

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

### Step 2 — Create SSM IAM Role

Check existing names:

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For unused names, `NoSuchEntity` is expected.

Create:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM propagation.

---

## 13. Prepare the HTTP Server

Create `server-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab15

cat > /opt/lab15/index.html <<'HTML'
AWS VPC Troubleshooting Lab 15

Server: Availability Zone B
Service: HTTP
Port: 8080
Status: Running
HTML

cat > /etc/systemd/system/lab15-http.service <<'UNIT'
[Unit]
Description=Lab 15 Cross-AZ HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab15
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab15-http.service
```

The script creates a test HTTP service that listens on port 8080 and starts automatically.

---

## 14. Launch EC2 Instances

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

### Step 3 — Launch Client EC2 in AZ A

```bash
export CLIENT_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_A_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab15-client-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch Server EC2 in AZ B

```bash
export SERVER_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_B_ID,Groups=$SERVER_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://server-user-data.sh \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab15-server-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Wait for Both Instances

```bash
aws ec2 wait instance-running \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify AZ Placement

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 7 — Record Private IPs

```bash
export CLIENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

export SERVER_IP=$(aws ec2 describe-instances \
  --instance-ids "$SERVER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "Client: $CLIENT_IP"
echo "Server: $SERVER_IP"
```

---

## 15. Establish Healthy Cross-AZ Connectivity

### Step 1 — Check SSM Status

```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm both lab instances are `Online`.

### Step 2 — Verify Server Application

Connect to the AZ B server:

```bash
aws ssm start-session \
  --target "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab15-http.service
```

Expected: `active`.

Verify local HTTP:

```bash
curl --noproxy '*' -sS \
  http://127.0.0.1:8080/
```

Expected: the Lab 15 page.

Exit.

### Step 3 — Test Cross-AZ HTTP

Connect to the AZ A client:

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside the client, enter the server's actual private IP:

```bash
export SERVER_IP="10.150.2.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: HTTP 200.

### Step 4 — Configure Background Connectivity Monitoring

Inside the client:

```bash
sudo tee /usr/local/bin/lab15-probe.sh > /dev/null <<'EOF'
#!/bin/bash

SERVER_IP="$1"
LOG="/var/tmp/lab15-connectivity.log"

for i in $(seq 1 120); do

  printf "%s " "$(date -u +%FT%TZ)" >> "$LOG"

  if curl --noproxy '*' -fsS \
     --connect-timeout 3 \
     --max-time 5 \
     "http://${SERVER_IP}:8080/" \
     -o /dev/null; then

    echo "CROSS_AZ_HTTP=SUCCESS" >> "$LOG"

  else

    echo "CROSS_AZ_HTTP=FAILED" >> "$LOG"

  fi

  sleep 10
done
EOF
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/lab15-probe.sh
```

Start:

```bash
sudo systemd-run \
  --unit=lab15-probe \
  --collect \
  /usr/local/bin/lab15-probe.sh "$SERVER_IP"
```

Verify:

```bash
sudo tail -n 10 /var/tmp/lab15-connectivity.log
```

Expected: `CROSS_AZ_HTTP=SUCCESS`.

Exit the session.

---

## 16. Reproduce the Multi-AZ Failure

### Step 1 — Verify Custom NACL

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].{Associations:Associations,Rules:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Add High-Priority DENY Rule

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_B_ID" \
  --rule-number 90 \
  --protocol 6 \
  --rule-action deny \
  --cidr-block "$SUBNET_A_CIDR" \
  --port-range From=8080,To=8080 \
  --ingress \
  --region "$AWS_REGION"
```

### Step 3 — Verify NACL Rules

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Rule 90   DENY TCP 8080 from 10.150.1.0/24
Rule 100  ALLOW ALL
Rule *    DENY ALL
```

### Step 4 — Test Connection Failure

Connect to the AZ A client:

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside:

```bash
export SERVER_IP="10.150.2.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: connection timeout.

### Step 5 — Check Monitoring

```bash
sudo tail -n 20 /var/tmp/lab15-connectivity.log
```

Expected: `CROSS_AZ_HTTP=FAILED`.

Exit.

---

## 17. Troubleshooting Investigation

### Check 1 — EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'InstanceStatuses[].{ID:InstanceId,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: both instances remain healthy.

### Check 2 — Availability Zone Placement

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: instances are in two different AZs.

### Check 3 — Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Finding: local VPC route exists.

### Check 4 — Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" "$SERVER_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: security groups permit the HTTP connection.

### Check 5 — AZ A NACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_A_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: default NACL permits traffic.

### Check 6 — AZ B NACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_B_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Associations:Associations,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: inbound NACL rule 90 denies TCP 8080 from AZ A.

### Check 7 — Verify Server Application

Connect to the AZ B server:

```bash
aws ssm start-session \
  --target "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside:

```bash
sudo systemctl is-active lab15-http.service

curl --noproxy '*' -sS \
  http://127.0.0.1:8080/
```

Expected: the application remains available locally.

### Investigation Summary

| Component | Finding |
|---|---|
| Client EC2 | Healthy |
| Server EC2 | Healthy |
| Availability Zones | Available |
| VPC routing | Correct |
| Security groups | Correct |
| AZ A NACL | Allows traffic |
| AZ B NACL | Rule 90 denies TCP 8080 |
| Server application | Running |
| Root cause | NACL rule priority and deny action |

---

## 18. Root Cause Analysis

### Root Cause

A high-priority inbound NACL rule on the AZ B subnet denied TCP 8080 traffic originating from the AZ A subnet.

### Technical Explanation

The client EC2 instance sends an HTTP request to the server's private IP address.

The VPC local route correctly handles the packet between the two subnets.

The server security group permits TCP 8080 from the client security group.

However, the AZ B subnet's custom NACL contains the following rule:

```text
Rule 90
Direction: Inbound
Protocol: TCP
Destination Port: 8080
Source: 10.150.1.0/24
Action: DENY
```

The NACL also contains a broad allow rule numbered 100.

Because AWS evaluates NACL entries in ascending rule-number order, rule 90 is evaluated first.

The incoming request matches rule 90 and is denied.

The lower-priority allow rule does not override it.

### Root Cause Flow

```text
Client EC2 — AZ A
        |
        v
TCP 8080 Request
        |
        v
VPC Local Route
        |
        v
AZ B Subnet NACL
        |
        v
Rule 90: DENY
        |
        X
Request Blocked
        |
        X
HTTP Timeout
```

### Five Whys

1. **Why did the HTTP request fail?** The server subnet NACL denied the traffic.
2. **Why did the NACL deny traffic?** Rule 90 matched TCP 8080 requests from the client subnet.
3. **Why didn't the allow rule work?** Rule 90 was evaluated before rule 100.
4. **Why were security groups not the problem?** They already permitted the intended HTTP connection.
5. **How can this be prevented?** Use controlled NACL changes, review rule priorities, and verify network communication after deployments.

---

## 19. Remediation

### Step 1 — Remove the DENY Rule

```bash
aws ec2 delete-network-acl-entry \
  --network-acl-id "$NACL_B_ID" \
  --rule-number 90 \
  --ingress \
  --region "$AWS_REGION"
```

### Step 2 — Verify NACL Configuration

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Inbound rule 100  ALLOW ALL
Outbound rule 100 ALLOW ALL
```

### Step 3 — Test Cross-AZ HTTP

Connect to the AZ A client:

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside:

```bash
export SERVER_IP="10.150.2.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: HTTP 200.

### Step 4 — Verify HTTP Status

```bash
curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'HTTP Status: %{http_code}\n' \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected:

```text
HTTP Status: 200
```

### Step 5 — Check Monitoring Logs

```bash
sudo cat /var/tmp/lab15-connectivity.log
```

Illustrative results:

```text
CROSS_AZ_HTTP=SUCCESS
CROSS_AZ_HTTP=FAILED
CROSS_AZ_HTTP=FAILED
CROSS_AZ_HTTP=SUCCESS
```

Use your actual test output and timestamps when recording incident evidence.

### Verification Matrix

| Component | Healthy Baseline | During Incident | After Fix |
|---|---|---|---|
| EC2 instances | Running | Running | Running |
| VPC route | Correct | Correct | Correct |
| Security groups | Correct | Correct | Correct |
| NACL rule 90 | Absent | Deny | Removed |
| HTTP server | Running | Running | Running |
| Client HTTP | Success | Timeout | Success |
| Cross-AZ connectivity | Working | Blocked | Restored |

### Success Criteria

- Instances are deployed across two different Availability Zones.
- The healthy client-to-server connection is verified.
- NACL rule 90 causes the intended failure.
- The blocking rule is identified through investigation.
- Rule 90 is removed.
- HTTP connectivity is restored.
- Temporary resources are safely deleted.

---

## 20. Production Best Practices

### Multi-AZ Networking Troubleshooting Checklist

1. Verify EC2 instances are running.
2. Confirm their Availability Zones.
3. Identify the source and destination subnets.
4. Verify private IPv4 addresses.
5. Check effective route tables.
6. Confirm the VPC local route exists.
7. Inspect source security group outbound rules.
8. Inspect destination security group inbound rules.
9. Examine NACL rules for both subnets.
10. Check NACL rule numbers and evaluation order.
11. Confirm the destination service is running.
12. Test actual application connectivity.
13. Apply least-privilege remediation.
14. Verify connectivity after the change.

### Common Multi-AZ Failure Causes

| Symptom | Possible Cause |
|---|---|
| Connection timeout | NACL or security group blocking traffic |
| One AZ works but another fails | AZ-specific subnet or network configuration |
| Application works locally only | Network restriction or wrong service binding |
| Cross-AZ requests fail | Route table, SG, or NACL misconfiguration |
| Return packets blocked | Missing outbound/inbound NACL permissions |
| EC2 running but application unavailable | Application or operating-system issue |

### Prevention

- Manage VPC networking through Terraform.
- Use GitHub pull requests to review NACL changes.
- Document network ACL rule priorities.
- Avoid unnecessary deny rules.
- Apply security groups as the primary fine-grained workload access control.
- Monitor service availability across AZs.
- Validate inter-subnet communication after deployments.
- Test both request and return traffic paths.
- Use VPC Flow Logs and Reachability Analyzer where appropriate.

### Important Production Note

This lab deliberately uses broad NACL allow rules to isolate the impact of one deny rule.

Production environments should follow organizational security requirements and should not automatically copy these broad NACL permissions.

---

## 21. Interview Questions and Answers

### Q1. Can EC2 instances in different Availability Zones communicate privately?

Yes. EC2 instances in different AZs of the same VPC can use the VPC-local route to communicate privately.

### Q2. Is VPC peering needed between two AZs?

No. VPC peering is used to connect separate VPCs.

### Q3. What caused the network failure in this lab?

A custom NACL on the server subnet denied inbound TCP 8080 from the client subnet.

### Q4. Why did the deny rule override the allow rule?

NACL rules are evaluated from the lowest rule number upward. Rule 90 matched before rule 100.

### Q5. Are NACLs stateful?

No. They are stateless.

### Q6. What does stateless mean for a NACL?

Return traffic must be explicitly permitted by the relevant NACL rules.

### Q7. Are security groups stateful?

Yes. Responses to permitted connections are automatically allowed by security group connection tracking.

### Q8. Why didn't the security group solve this issue?

Security groups and NACLs are separate network security controls. Traffic must satisfy both.

### Q9. Why was the Internet Gateway unnecessary for application traffic?

The client and server communicate using private IPs within the same VPC.

### Q10. Does a cross-AZ timeout always indicate an AZ outage?

No. Incorrect subnet routing, NACLs, security groups, or application configuration can cause the same symptom.

### Q11. How is this different from Lab 14?

Lab 14 investigates a missing security group rule with Reachability Analyzer. Lab 15 investigates a subnet NACL deny rule affecting cross-AZ connectivity.

### Q12. How would you explain this lab in an interview?

> I deployed two EC2 instances in different Availability Zones within the same AWS VPC. The client in AZ A communicated with an HTTP server in AZ B using private IP addresses. After verifying connectivity, I intentionally configured a high-priority NACL rule on the server subnet to deny TCP 8080 traffic from the client subnet. The connection began timing out while the instances, route tables, and security groups remained healthy. I investigated the NACL rule order, identified the blocking rule, removed it, and verified that HTTP connectivity recovered.

---

## 22. Cleanup

**Warning:** Verify AWS account identity, resource IDs, and ownership tags before deleting resources.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Record EBS Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Volumes:BlockDeviceMappings[].Ebs}' \
  --output json \
  --region "$AWS_REGION"
```

Verify that root volumes have `DeleteOnTermination=true`.

### Step 3 — Terminate EC2 Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$CLIENT_INSTANCE_ID" "$SERVER_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Restore Default NACL Association

Retrieve the current association:

```bash
export CURRENT_NACL_ASSOC_B=$(aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query "NetworkAcls[0].Associations[?SubnetId=='$SUBNET_B_ID'].NetworkAclAssociationId | [0]" \
  --output text \
  --region "$AWS_REGION")
```

Restore the default NACL:

```bash
aws ec2 replace-network-acl-association \
  --association-id "$CURRENT_NACL_ASSOC_B" \
  --network-acl-id "$DEFAULT_NACL_ID" \
  --region "$AWS_REGION"
```

Verify the custom NACL has no subnet associations:

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_B_ID" \
  --query 'NetworkAcls[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 5 — Delete Custom NACL

```bash
aws ec2 delete-network-acl \
  --network-acl-id "$NACL_B_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Remove Security Group Reference

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Check Network Interface Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Continue after the lab's EC2 network interfaces have been removed.

### Step 8 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$SERVER_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete IAM Resources

Verify the role belongs to this lab:

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Delete:

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

### Step 10 — Delete Route Table Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_B" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify Cleanup

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

Verify that the root EBS volumes, custom NACL, security groups, subnets, route table, Internet Gateway, and VPC have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Client EC2 | Terminated |
| Server EC2 | Terminated |
| Root EBS volumes | Deleted |
| Custom AZ B NACL | Deleted |
| Client security group | Deleted |
| Server security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Custom route table | Deleted |
| AZ A subnet | Deleted |
| AZ B subnet | Deleted |
| Internet Gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 23. Repository Structure

```text
15-multi-az-network-connectivity-failure/
├── README.md
├── ec2-trust-policy.json
└── server-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for the EC2 SSM role |
| `server-user-data.sh` | Configures the Python HTTP server in AZ B |

Do not commit AWS credentials, private keys, or other sensitive information.

---

## 24. Lessons Learned

This lab demonstrates how a subnet-level NACL misconfiguration can prevent application communication between two Availability Zones.

Both EC2 instances were running, and the VPC local route was correct.

The security groups also permitted the intended TCP 8080 connection.

However, the AZ B subnet's custom NACL contained a high-priority deny rule.

Because NACLs evaluate the lowest numbered matching rule first, the deny rule blocked the connection even though a lower-priority allow rule existed.

Removing the deny rule restored application connectivity.

This exercise also demonstrates that cross-AZ connectivity failures do not necessarily indicate an AWS Availability Zone outage.

**Key Lesson:** When troubleshooting inter-subnet or cross-AZ connectivity, inspect both security groups and NACL rule priorities. Correct route tables and security groups do not guarantee connectivity if a subnet NACL denies the traffic.

---

## 25. Skills Demonstrated

- AWS Multi-AZ networking
- VPC and subnet architecture
- EC2 deployment across Availability Zones
- VPC local routing
- Network ACL troubleshooting
- NACL rule evaluation and priority
- Stateful vs. stateless security
- Security group configuration
- AWS Systems Manager
- AWS CLI v2
- Linux networking
- HTTP connectivity testing
- Network fault injection
- Root cause analysis
- Network remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-015 |
| Problem | Cross-AZ HTTP connectivity failure |
| Root Cause | NACL rule 90 denying TCP 8080 |
| EC2 Health | Healthy |
| VPC Routing | Correct |
| Security Groups | Correct |
| Server Application | Running |
| Initial HTTP Test | Successful |
| HTTP During Failure | Timeout |
| Remediation | Remove NACL deny rule |
| HTTP After Fix | Successful |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Network ACLs control traffic at the subnet level and evaluate rules by priority. A high-priority deny rule can block cross-AZ communication even when the instances, routes, and security groups are configured correctly.
