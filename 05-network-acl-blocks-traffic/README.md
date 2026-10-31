# Lab 05 — Network ACL Blocks Traffic

## Overview

This lab demonstrates how to troubleshoot an Amazon VPC network connectivity failure caused by an incorrectly configured Network Access Control List (NACL).

Two Amazon EC2 instances are deployed in separate subnets within the same VPC. One acts as an HTTP client, while the other runs a Python web server on TCP port `8080`.

Both instances are healthy, their security groups are configured correctly, and the VPC route table provides valid local routing. However, a higher-priority inbound NACL rule blocks traffic from the client subnet to the web server.

The purpose is to reproduce a realistic AWS networking incident, investigate the failure, identify the root cause, apply remediation, verify restored connectivity, and clean up the temporary infrastructure.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce NACL Failure → Investigate → Identify Root Cause → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-005 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` (two instances) |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Python HTTP Server |
| VPC CIDR | `10.50.0.0/16` |
| Client Subnet | `10.50.1.0/24` |
| Server Subnet | `10.50.2.0/24` |
| Application Port | TCP `8080` |
| Network ACL | Custom NACL attached to server subnet |
| Fault | Inbound DENY rule 90 |
| Root Cause | NACL denies traffic before ALLOW rule 100 |
| Remediation | Remove incorrect DENY rule |
| Expected Result | HTTP 200 |
| Management | AWS Systems Manager Session Manager |

---

## 1. Production Incident Scenario

An application running on an EC2 instance needs to communicate with an internal HTTP service hosted on another EC2 instance.

The client and server are located in separate subnets inside the same VPC.

The application team reports that HTTP requests are timing out.

Initial investigation shows:

- The client EC2 instance is running.
- The server EC2 instance is running.
- The web server is listening on TCP 8080.
- The web server responds successfully to localhost requests.
- The server security group allows inbound TCP 8080 from the client security group.
- Both subnets have valid VPC-local routing.
- The server subnet's NACL contains an explicit DENY rule matching the incoming request.

### Expected Behavior

```text
Client EC2
    |
    | TCP 8080
    v
Server Subnet NACL
    |
    | ALLOW
    v
Server Security Group
    |
    | ALLOW
    v
HTTP Server
    |
    v
HTTP 200 OK
```

### Failure Behavior

```text
Client EC2
    |
    | TCP 8080
    v
Server Subnet NACL
    |
    | Rule 90: DENY
    X
Connection Timeout
```

### Potential Business Impact

- Internal service communication fails.
- Application API calls time out.
- Microservices cannot access dependencies.
- Application health checks fail.
- Deployment validation is interrupted.
- Availability and reliability decrease.

### Investigation Objective

Determine why the connection fails when routing and security groups are correct, then restore connectivity without changing unrelated infrastructure.

---

## 2. AWS Architecture

```text
                       AWS VPC
                    10.50.0.0/16
                           |
             +-------------+-------------+
             |                           |
      Client Subnet                Server Subnet
      10.50.1.0/24                 10.50.2.0/24
             |                           |
      Default NACL                 Custom NACL
      ALLOW Traffic                Rule 90: DENY TCP 8080
             |                     Rule 100: ALLOW All
             |                           |
        Client EC2                 Server EC2
        Client SG                  Server SG
             |                     ALLOW TCP 8080
             |                           |
             +-------- TCP 8080 ---------X
                                         |
                                   Python HTTP
                                      Server
```

### Healthy Traffic Path

```text
Client EC2
    |
    v
Client Security Group
    |
    v
Client Subnet NACL
    |
    v
VPC Local Route
    |
    v
Server Subnet NACL
    |
    v
Server Security Group
    |
    v
Python HTTP Server
```

### Network Components

| Component | Purpose |
|---|---|
| VPC | Provides private network isolation |
| Client subnet | Hosts the HTTP client |
| Server subnet | Hosts the web server |
| Client security group | Controls client traffic |
| Server security group | Allows HTTP from client SG |
| Default NACL | Permits client subnet traffic |
| Custom NACL | Controls server subnet traffic |
| Route table | Provides local and internet routes |
| Internet gateway | Enables outbound SSM connectivity |
| Systems Manager | Provides administrative access without SSH |

The two EC2 instances receive public IPv4 addresses for Systems Manager connectivity, but application communication uses their private IPv4 addresses.

---

## 3. Understanding Network ACLs

A Network Access Control List is a stateless firewall that controls traffic entering and leaving an AWS subnet.

Unlike security groups, NACLs support both ALLOW and DENY rules.

### Important NACL Characteristics

1. NACLs operate at the subnet boundary.
2. NACLs evaluate rules in ascending numerical order.
3. The first matching rule determines the result.
4. NACLs support both ALLOW and DENY actions.
5. NACLs are stateless.
6. Return traffic must independently match an appropriate allow rule.
7. Each subnet has one associated NACL at a time.

### Security Group vs. Network ACL

| Feature | Security Group | Network ACL |
|---|---|---|
| Scope | Network interface | Subnet |
| Stateful | Yes | No |
| Allow rules | Yes | Yes |
| Deny rules | No | Yes |
| Rule evaluation | Matching allow rules | Ascending rule number |
| Return traffic | Automatically allowed for permitted connections | Requires applicable allow rules |

### NACL Rule Priority

Our baseline rules are:

| Rule | Direction | Protocol | CIDR | Action |
|---|---|---|---|---|
| 100 | Inbound | All | `0.0.0.0/0` | ALLOW |
| 100 | Outbound | All | `0.0.0.0/0` | ALLOW |
| `*` | Both | All | `0.0.0.0/0` | DENY |

During failure simulation:

| Rule | Direction | Protocol | CIDR | Action |
|---|---|---|---|---|
| 90 | Inbound | TCP 8080 | `10.50.1.0/24` | DENY |
| 100 | Inbound | All | `0.0.0.0/0` | ALLOW |

Rule 90 matches first. Therefore, rule 100 never gets evaluated for that packet.

---

## 4. Prerequisites and Safety

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Permissions to create and delete VPC resources
- EC2 management permissions
- IAM role and instance profile permissions
- Session Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated lab VPC.
- Do not modify the default VPC.
- Use disposable EC2 instances.
- Do not change shared NACLs.
- Keep inbound SSH closed.
- Limit the intentional DENY rule to the client subnet and TCP 8080.
- Confirm ownership before deleting resources.
- Remove temporary AWS resources after testing.

### Cost Considerations

The lab uses two EC2 instances, root EBS volumes, and public IPv4 addresses.

There is no NAT gateway or paid VPC interface endpoint.

The EC2 instances and public IPv4 addresses may incur charges until they are removed.

---

## 5. Prepare the Lab Environment

Run all AWS CLI commands from Ubuntu WSL2 unless specified otherwise.

### Step 1 — Configure Environment Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab05"

export VPC_NAME="cloud-lab05-vpc"
export VPC_CIDR="10.50.0.0/16"

export CLIENT_SUBNET_NAME="cloud-lab05-client-subnet"
export SERVER_SUBNET_NAME="cloud-lab05-server-subnet"

export CLIENT_CIDR="10.50.1.0/24"
export SERVER_CIDR="10.50.2.0/24"

export IGW_NAME="cloud-lab05-igw"
export RT_NAME="cloud-lab05-public-rt"

export CLIENT_SG_NAME="cloud-lab05-client-sg"
export SERVER_SG_NAME="cloud-lab05-server-sg"

export CLIENT_NAME="cloud-lab05-client"
export SERVER_NAME="cloud-lab05-server"

export NACL_NAME="cloud-lab05-server-nacl"

export ROLE_NAME="cloud-lab05-ssm-role"
export PROFILE_NAME="cloud-lab05-ssm-profile"

export APP_PORT="8080"
```

Verify AWS identity:

```bash
aws sts get-caller-identity
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

Select a supported AZ:

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

Do not create a duplicate if Lab 05 resources already exist.

---

## 6. Create the VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

Enable DNS:

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

Verify:

```bash
echo "$VPC_ID"
```

---

## 7. Create Client and Server Subnets

### Step 1 — Create Client Subnet

```bash
export CLIENT_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$CLIENT_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=$CLIENT_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Server Subnet

```bash
export SERVER_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SERVER_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=$SERVER_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Subnets

```bash
aws ec2 describe-subnets \
  --subnet-ids "$CLIENT_SUBNET_ID" "$SERVER_SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table \
  --region "$AWS_REGION"
```

---

## 8. Configure Internet Gateway and Routing

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

### Step 3 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Associate Client Subnet

```bash
export CLIENT_RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$CLIENT_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Associate Server Subnet

```bash
export SERVER_RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SERVER_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.50.0.0/16 → local
0.0.0.0/0    → Internet Gateway
```

---

## 9. Configure Security Groups

### Step 1 — Create Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab05 client security group" \
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
  --description "Lab05 server security group" \
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

### Step 4 — Verify

```bash
aws ec2 describe-security-groups \
  --group-ids "$SERVER_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the server security group permits TCP 8080 from the client SG.

---

## 10. Create and Configure a Custom NACL

### Step 1 — Create Custom NACL

```bash
export NACL_ID=$(aws ec2 create-network-acl \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=network-acl,Tags=[{Key=Name,Value=$NACL_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'NetworkAcl.NetworkAclId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Allow Inbound Traffic

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --rule-number 100 \
  --protocol -1 \
  --rule-action allow \
  --cidr-block "0.0.0.0/0" \
  --ingress \
  --region "$AWS_REGION"
```

### Step 3 — Allow Outbound Traffic

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --rule-number 100 \
  --protocol -1 \
  --rule-action allow \
  --cidr-block "0.0.0.0/0" \
  --egress \
  --region "$AWS_REGION"
```

**Note:** These broad rules establish a simple baseline only in this isolated lab. Production NACLs should be designed according to workload requirements.

### Step 4 — Find Existing NACL Association

```bash
export OLD_NACL_ASSOC_ID=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SERVER_SUBNET_ID" \
  --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Associate Custom NACL With Server Subnet

```bash
export NACL_ASSOC_ID=$(aws ec2 replace-network-acl-association \
  --association-id "$OLD_NACL_ASSOC_ID" \
  --network-acl-id "$NACL_ID" \
  --query NewAssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Verify NACL

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].{Associations:Associations,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the server subnet uses the custom NACL with inbound and outbound rule 100 allowing traffic.

---

## 11. Create IAM Role for Session Manager

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

### Step 2 — Create IAM Role

First confirm the role name and instance profile are unused.

```bash
aws iam get-role --role-name "$ROLE_NAME"
aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME"
```

For new resources, `NoSuchEntity` is expected.

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach SSM Policy

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

Verify:

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output table
```

Allow IAM propagation before launching EC2.

---

## 12. Create HTTP Server User Data

Create `server-user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

mkdir -p /opt/vpc-lab05

cat > /opt/vpc-lab05/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>VPC Lab 05</title></head>
<body>
<h1>VPC LAB 05 - NACL TROUBLESHOOTING</h1>
<p>Server is responding on TCP 8080.</p>
</body>
</html>
HTML

cat > /etc/systemd/system/vpc-lab05-web.service <<'UNIT'
[Unit]
Description=VPC Lab 05 HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/vpc-lab05
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 /opt/vpc-lab05
chmod 644 /opt/vpc-lab05/index.html
chmod 644 /etc/systemd/system/vpc-lab05-web.service

systemctl daemon-reload
systemctl enable --now vpc-lab05-web.service
```

### What the Script Does

- Creates a directory for the web application.
- Writes a simple HTML page.
- Creates a systemd service.
- Runs Python's HTTP server on port 8080.
- Enables the service to start automatically.

---

## 13. Launch Both EC2 Instances

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

Do not launch duplicates.

### Step 3 — Launch Server EC2

```bash
export SERVER_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SERVER_SUBNET_ID,Groups=$SERVER_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://server-user-data.sh \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$SERVER_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch Client EC2

```bash
export CLIENT_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$CLIENT_SUBNET_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$CLIENT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Wait for Both Instances

```bash
aws ec2 wait instance-running \
  --instance-ids "$SERVER_ID" "$CLIENT_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$SERVER_ID" "$CLIENT_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Retrieve Private IP Addresses

```bash
export SERVER_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$SERVER_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

export CLIENT_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$CLIENT_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "Server: $SERVER_PRIVATE_IP"
echo "Client: $CLIENT_PRIVATE_IP"
```

### Step 7 — Verify SSM Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$SERVER_ID,$CLIENT_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration: both instances `Online`.

---

## 14. Establish Healthy Connectivity

### Step 1 — Connect to Server

```bash
aws ssm start-session \
  --target "$SERVER_ID" \
  --region "$AWS_REGION"
```

Alternatively, use Session Manager from the AWS Console.

### Step 2 — Check Web Service

Inside server EC2:

```bash
sudo systemctl status vpc-lab05-web.service --no-pager
sudo ss -lntp | grep ':8080'
curl -fsS http://127.0.0.1:8080/
```

Expected: service active and HTTP response returned.

### Step 3 — Connect to Client

Exit server Session Manager and connect to the client.

```bash
aws ssm start-session \
  --target "$CLIENT_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Test HTTP

Inside client EC2, set the server's actual private IPv4 address:

```bash
export SERVER_PRIVATE_IP="10.50.2.REPLACE"
```

Then:

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 8 \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Check HTTP status:

```bash
curl -s -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected:

```text
HTTP Status: 200
```

This confirms that the initial application, routing, security group, and NACL configurations work together.

---

## 15. Reproduce the NACL Failure

### Step 1 — Create DENY Rule 90

From WSL2:

```bash
aws ec2 create-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --rule-number 90 \
  --protocol 6 \
  --port-range "From=8080,To=8080" \
  --rule-action deny \
  --cidr-block "$CLIENT_CIDR" \
  --ingress \
  --region "$AWS_REGION"
```

### Step 2 — Verify the DENY Rule

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Expected relevant configuration:

```text
Rule 90:
Direction: Inbound
Source: 10.50.1.0/24
Protocol: TCP
Port: 8080
Action: DENY

Rule 100:
Direction: Inbound
Source: 0.0.0.0/0
Protocol: All
Action: ALLOW
```

Since rule 90 has a lower number, it is evaluated first.

### Step 3 — Reproduce Connectivity Failure

Inside client EC2:

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 8 \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected: connection timeout.

Example:

```text
curl: (28) Failed to connect to 10.50.2.x port 8080
```

The server remains healthy, but the incoming packet is denied by the server subnet NACL.

---

## 16. Troubleshooting Investigation

### Check 1 — Confirm Security Group Permissions

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" "$SERVER_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: server SG allows TCP 8080 from client SG.

### Check 2 — Verify VPC Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected: VPC-local route present.

### Check 3 — Inspect Server Subnet NACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SERVER_SUBNET_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: custom NACL with inbound DENY rule 90.

### Check 4 — Verify HTTP Server Is Healthy

Inside server EC2:

```bash
sudo systemctl is-active vpc-lab05-web.service
curl -fsS http://127.0.0.1:8080/
```

Expected: application working.

### Investigation Summary

| Component | Finding |
|---|---|
| Client EC2 | Running |
| Server EC2 | Running |
| Python HTTP server | Healthy |
| Local HTTP test | Successful |
| Security groups | Correct |
| VPC routing | Correct |
| Client subnet NACL | Default allow rules |
| Server subnet NACL | TCP 8080 denied |
| HTTP from client | Timeout |
| Root cause | Higher-priority NACL deny rule |

---

## 17. Root Cause Analysis

### Root Cause

The custom NACL associated with the server subnet contained a higher-priority inbound DENY rule for TCP port 8080.

The rule matched packets originating from the client subnet.

### Technical Explanation

AWS evaluates NACL rules in ascending rule-number order.

The first matching rule determines whether the packet is permitted.

The incoming HTTP request matches:

```text
Rule:       90
Direction:  Inbound
Source:     10.50.1.0/24
Protocol:   TCP
Port:       8080
Action:     DENY
```

As a result, rule 100's ALLOW action never applies.

### Five Whys

1. **Why did HTTP fail?** The request timed out.
2. **Why did the packet not reach the server?** The server subnet NACL denied it.
3. **Why did the ALLOW rule not work?** The lower-numbered DENY rule matched first.
4. **Why didn't the security group rule fix the issue?** The NACL is an independent filtering control.
5. **How can this be prevented?** Review NACL rule ordering, scope, and traffic requirements before applying network changes.

---

## 18. Remediation

### Step 1 — Remove DENY Rule 90

From WSL2:

```bash
aws ec2 delete-network-acl-entry \
  --network-acl-id "$NACL_ID" \
  --rule-number 90 \
  --ingress \
  --region "$AWS_REGION"
```

### Step 2 — Verify the Correct Rule Set

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Expected: rule 90 removed.

### Step 3 — Retest HTTP

Reconnect to client EC2 if necessary.

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 8 \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

### Step 4 — Verify HTTP 200

```bash
curl -s -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected:

```text
HTTP Status: 200
```

### Verification Matrix

| Component | Healthy | Failure | Restored |
|---|---|---|---|
| Client EC2 | Running | Running | Running |
| Server EC2 | Running | Running | Running |
| Web server | Healthy | Healthy | Healthy |
| Security groups | Correct | Correct | Correct |
| Route table | Correct | Correct | Correct |
| NACL inbound TCP 8080 | Allowed | Denied by rule 90 | Allowed |
| Client HTTP request | Success | Timeout | Success |
| HTTP status | 200 | Unavailable | 200 |

---

## 19. Stateless NACLs and Ephemeral Ports

One of the most important concepts in this lab is the difference between stateful security groups and stateless NACLs.

### Example TCP Connection

```text
Request:
Client 10.50.1.25:45000 → Server 10.50.2.40:8080

Response:
Server 10.50.2.40:8080 → Client 10.50.1.25:45000
```

The client chooses a temporary source port, called an ephemeral port.

The server sends its response to that port.

### NACL Traffic Requirements

| Subnet | Direction | Required Destination Port |
|---|---|---|
| Client subnet | Outbound | TCP 8080 |
| Server subnet | Inbound | TCP 8080 |
| Server subnet | Outbound | Client ephemeral port |
| Client subnet | Inbound | Client ephemeral port |

Because NACLs are stateless, both directions require appropriate allow rules.

### Check Linux Ephemeral Port Range

Run inside client EC2:

```bash
cat /proc/sys/net/ipv4/ip_local_port_range
```

The actual range depends on operating-system configuration. Do not assume every client uses the same ephemeral port range.

### Why This Lab's Return Traffic Works

The original NACL rule 100 allows all inbound and outbound traffic.

After removing rule 90, both the HTTP request and its return traffic can pass.

The security groups remain the more restrictive application-level network access controls in this lab.

---

## 20. Production Engineering Best Practices

### NACL Design

- Review rule numbers carefully.
- Use specific CIDRs when possible.
- Avoid unnecessary broad DENY rules.
- Understand inbound and outbound requirements.
- Consider return traffic and ephemeral ports.
- Maintain documentation of NACL associations.
- Keep default rules separate from special-purpose restrictions.
- Test application connectivity after changes.

### Troubleshooting Methodology

1. Identify the affected source and destination.
2. Verify the application is running.
3. Check source security group egress.
4. Check destination security group ingress.
5. Inspect the effective subnet route tables.
6. Inspect source and destination NACLs.
7. Review rule priority and matching conditions.
8. Verify return traffic requirements.
9. Apply the minimum necessary remediation.
10. Retest and document the incident.

### Prevention

- Manage NACL rules with Terraform or CloudFormation.
- Use pull requests to review networking changes.
- Maintain consistent AWS resource tags.
- Monitor connectivity and application health.
- Use VPC Flow Logs for traffic metadata when appropriate.
- Use Reachability Analyzer for configuration-based network path analysis.
- Document expected client-to-server traffic requirements.

---

## 21. Interview Questions and Answers

### Q1. What is a Network ACL?

A Network ACL is a stateless subnet-level firewall that controls inbound and outbound traffic using numbered allow and deny rules.

### Q2. How are NACL rules evaluated?

AWS evaluates rules from the lowest number upward. The first matching rule determines the action.

### Q3. Why did rule 90 block traffic despite rule 100 allowing it?

Rule 90 was evaluated first and matched the client's HTTP request.

### Q4. What is the difference between a security group and a NACL?

Security groups are stateful and contain allow rules. NACLs are stateless and contain allow and deny rules.

### Q5. Why was the HTTP server still healthy?

The NACL blocked traffic crossing the subnet boundary, not the local web server process.

### Q6. Why did the correct security group rule not prevent the failure?

Security groups and NACLs are independent controls. Both must permit the traffic.

### Q7. What are ephemeral ports?

Temporary source ports used by clients when initiating connections.

### Q8. Why must NACLs permit return traffic?

NACLs do not track connection state, so responses need their own matching allow rules.

### Q9. Can multiple subnets use the same NACL?

Yes. A NACL can be associated with multiple subnets, but each subnet uses one NACL at a time.

### Q10. Why did this lab use two subnets?

To ensure the application traffic crosses subnet boundaries and is evaluated by subnet NACLs.

### Q11. What command creates a NACL entry?

`aws ec2 create-network-acl-entry`

### Q12. What command removes a NACL entry?

`aws ec2 delete-network-acl-entry`

### Q13. How would you explain this incident in an interview?

> I created an isolated AWS VPC with two EC2 instances in different subnets. One instance hosted a Python HTTP server on TCP 8080, and the other acted as a client. I verified that security groups, routing, and the application were configured correctly. Then I intentionally added an inbound NACL DENY rule with priority 90, which blocked the HTTP request before the ALLOW rule 100 could match. I investigated the NACL rule ordering, removed the incorrect rule, and confirmed the client received HTTP 200 again. The exercise strengthened my understanding of stateless subnet filtering and AWS network troubleshooting.

---

## 22. Cleanup

**Important:** Confirm all resources belong exclusively to `VPC-Troubleshooting-Lab05` before deleting them.

### Step 1 — Verify AWS Identity and Lab Tags

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the `Project=VPC-Troubleshooting-Lab05` tag.

### Step 2 — Check Root EBS Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.{Volume:VolumeId,DeleteOnTermination:DeleteOnTermination}' \
  --output table \
  --region "$AWS_REGION"
```

Record the volume IDs and verify deletion settings.

### Step 3 — Terminate Both Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Find Default VPC NACL

```bash
export DEFAULT_NACL_ID=$(aws ec2 describe-network-acls \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=default,Values=true" \
  --query 'NetworkAcls[0].NetworkAclId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Restore Default NACL Association

Verify the current association first:

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

Then:

```bash
aws ec2 replace-network-acl-association \
  --association-id "$NACL_ASSOC_ID" \
  --network-acl-id "$DEFAULT_NACL_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Delete Custom NACL

Confirm no subnet associations remain:

```bash
aws ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

Then:

```bash
aws ec2 delete-network-acl \
  --network-acl-id "$NACL_ID" \
  --region "$AWS_REGION"
```

Do not delete the VPC's default NACL.

### Step 7 — Revoke Security Group Reference

If the rule is still present:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Check Network Interface Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

When lab network interfaces are removed:

```bash
aws ec2 delete-security-group \
  --group-id "$SERVER_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify IAM Role Ownership

```bash
aws iam list-role-tags --role-name "$ROLE_NAME"
```

Confirm that the role and instance profile are not used by other workloads.

### Step 10 — Delete IAM Resources

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

### Step 11 — Remove Route Table Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$CLIENT_RT_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$SERVER_RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

Do not manually delete the main route table.

### Step 13 — Delete Both Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$CLIENT_SUBNET_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SERVER_SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Remove Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify VPC Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output table \
  --region "$AWS_REGION"
```

Confirm no remaining workloads or networking resources depend on the VPC.

### Step 16 — Delete Dedicated VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Verify EC2 Cleanup

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

Confirm the root EBS volumes were also removed.

### Cleanup Summary

| Resource | Expected Outcome |
|---|---|
| Client EC2 | Terminated |
| Server EC2 | Terminated |
| EBS root volumes | Deleted |
| Client security group | Deleted |
| Server security group | Deleted |
| Custom NACL | Deleted |
| Default NACL | Preserved until VPC deletion |
| Custom route table | Deleted |
| Client subnet | Deleted |
| Server subnet | Deleted |
| Internet gateway | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 23. Repository Structure

```text
05-network-acl-blocks-traffic/
├── README.md
├── ec2-trust-policy.json
└── server-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation, reproduction, troubleshooting, remediation, and cleanup |
| `ec2-trust-policy.json` | EC2 trust relationship for Systems Manager |
| `server-user-data.sh` | Installs and starts the Python HTTP server |

Do not commit AWS credentials, private keys, or sensitive account information.

---

## 24. Lessons Learned

This lab demonstrates that network traffic may fail even when application processes, VPC routing, and security groups are correctly configured.

The failure was caused by a higher-priority NACL deny rule.

Since network ACLs evaluate numbered rules in ascending order, the explicit deny rule matched before the general allow rule.

Removing the incorrectly configured rule restored the expected network path.

The lab also highlights the importance of understanding ephemeral ports and bidirectional filtering when troubleshooting stateless network controls.

**Key Lesson:** Always inspect the effective NACL association, rule order, protocol, CIDR, port range, and traffic direction when investigating AWS subnet connectivity problems.

---

## 25. Skills Demonstrated

- Amazon VPC networking
- Network ACL configuration
- Stateless firewall troubleshooting
- NACL rule evaluation and priority
- EC2 communication across subnets
- TCP port troubleshooting
- Ephemeral port analysis
- Security group vs. NACL comparison
- Python HTTP server configuration
- AWS CLI v2
- AWS Systems Manager
- Linux networking diagnostics
- Root cause analysis
- Network remediation
- Resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-005 |
| Problem | Client cannot reach HTTP server |
| Root Cause | NACL rule 90 denies inbound TCP 8080 |
| Healthy Rule | Rule 100 allows traffic |
| Remediation | Remove incorrect rule 90 |
| Server Application | Healthy |
| Security Groups | Correct |
| VPC Routing | Correct |
| HTTP After Remediation | 200 |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** NACLs are stateless and evaluate rules in numerical order. A single higher-priority DENY rule can block an application even when its security groups and route tables are configured correctly.
