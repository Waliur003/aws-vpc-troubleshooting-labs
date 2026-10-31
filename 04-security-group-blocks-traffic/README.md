# Lab 04 — Amazon VPC Security Group Blocks Traffic

## Overview

This lab demonstrates how to troubleshoot a network connectivity failure between two Amazon EC2 instances caused by an incorrectly configured security group.

Both EC2 instances run inside the same VPC and subnet. One instance acts as an HTTP client, while the other runs a Python web server on TCP port `8080`.

Although the web server is running correctly and the VPC routing configuration is valid, the client cannot connect because the server's security group does not allow incoming traffic on the application port.

We intentionally reproduce the failure, investigate the networking components, identify the missing security group rule, apply least-privilege remediation, and verify successful HTTP connectivity.

**Troubleshooting workflow:**

Provision → Deploy Application → Reproduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-004 |
| AWS Services | VPC, EC2, IAM, Systems Manager |
| Difficulty | Beginner–Intermediate |
| AWS Region | `us-east-1` |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` (two instances) |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, Python HTTP Server, curl |
| VPC CIDR | `10.40.0.0/16` |
| Subnet CIDR | `10.40.1.0/24` |
| Application Port | TCP `8080` |
| Client | EC2 with client security group |
| Server | EC2 with server security group |
| Simulated Failure | Missing server inbound rule |
| Root Cause | Server security group blocks TCP 8080 |
| Remediation | Allow TCP 8080 from client security group |
| Expected Outcome | HTTP 200 response |
| Management | AWS Systems Manager Session Manager |

---

## 1. Production Incident Scenario

### Incident Description

An application team deploys a small internal web service on an EC2 instance.

Another EC2 instance in the same VPC needs to communicate with the service using HTTP on port `8080`.

The client cannot reach the application even though:

- Both instances are running.
- Both instances use private IPv4 addresses inside the same VPC.
- The Python HTTP server is active.
- The web server responds to local requests.
- The VPC route table contains the local route.
- The network ACL allows traffic.

The cloud engineer must determine why the connection fails and restore access without exposing the application to unnecessary networks.

### Expected Behavior

From the client EC2:

```bash
curl http://SERVER_PRIVATE_IP:8080/
```

Expected response:

```html
<h1>VPC LAB 04 - HTTP SERVER WORKING</h1>
```

### Actual Failure

The request fails with a connection timeout.

Example diagnostic message:

```text
curl: (28) Failed to connect to server port 8080: Connection timed out
```

This result is expected when the destination security group does not permit the incoming connection.

### Potential Business Impact

- Application-to-application communication fails.
- Internal APIs become unavailable.
- Microservices cannot reach dependencies.
- Health checks may fail.
- Deployment verification is blocked.
- Service availability and reliability decrease.

### Investigation Objective

Identify the filtering rule preventing client-to-server communication and restore connectivity using a restricted security group rule.

---

## 2. AWS Architecture

### Initial Architecture

```text
                  AWS VPC
                10.40.0.0/16
                       |
         +---------------------------+
         | Subnet: 10.40.1.0/24      |
         |                           |
         |    Client EC2             |
         |    Client Security Group  |
         |    Private IP             |
         |          |                |
         |          | TCP 8080       |
         |          v                |
         |    Server Security Group  |
         |    NO INBOUND RULE        |
         |          X                |
         |    Server EC2             |
         |    Python HTTP Server     |
         |    Port 8080              |
         +---------------------------+
```

### Corrected Architecture

```text
                  AWS VPC
                10.40.0.0/16
                       |
         +---------------------------+
         | Subnet: 10.40.1.0/24      |
         |                           |
         |    Client EC2             |
         |    Security Group A       |
         |          |                |
         |          | TCP 8080       |
         |          v                |
         |    Server Security Group B|
         |    ALLOW TCP 8080         |
         |    SOURCE: Client SG      |
         |          |                |
         |          v                |
         |    Server EC2             |
         |    Python HTTP Server     |
         |          |                |
         |          v                |
         |      HTTP 200 OK          |
         +---------------------------+
```

### Network Components

| Component | Purpose |
|---|---|
| VPC | Isolated AWS network |
| Subnet | Provides private IP addressing |
| Client EC2 | Sends HTTP requests |
| Server EC2 | Hosts web application |
| Client SG | Allows outbound connections |
| Server SG | Controls inbound application access |
| Route table | Provides local VPC routing |
| Network ACL | Subnet-level network filtering |
| Systems Manager | Secure EC2 administration |

Both instances have public IPv4 addresses for outbound management connectivity, but **the application requests use private IPv4 addresses and do not traverse the internet gateway**.

---

## 3. Understanding AWS Security Groups

A security group acts as a stateful virtual firewall associated with an EC2 network interface.

Security groups contain allow rules, not explicit deny rules.

### Inbound Rules

Inbound rules control which connections can enter the network interfaces associated with the security group.

For this lab:

```text
Protocol: TCP
Port:     8080
Source:   Client Security Group
```

### Outbound Rules

Outbound rules control traffic initiated from an instance.

Our client security group uses its initial default outbound allow rule.

### Stateful Behavior

Security groups are stateful.

When a connection is permitted, response traffic associated with the connection is automatically allowed.

This means the HTTP client does not need a separate inbound rule for the server's response.

### Security Group Referencing

Instead of allowing an entire VPC CIDR or the public internet, we can reference the client security group.

Example:

```text
Type:        Custom TCP
Protocol:    TCP
Port:        8080
Source:      sg-CLIENT
Destination: sg-SERVER
```

This allows the specified traffic from private IP addresses of interfaces associated with the referenced security group.

### Security Group vs Network ACL

| Feature | Security Group | Network ACL |
|---|---|---|
| Scope | Network interface | Subnet boundary |
| Stateful | Yes | No |
| Rules | Allow only | Allow and deny |
| Response traffic | Automatically permitted for allowed connections | Must be explicitly permitted |
| Rule evaluation | Aggregate applicable allow rules | Rule-number order |

---

## 4. Prerequisites and Safety

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- IAM permissions for EC2 and VPC operations
- Systems Manager Session Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated VPC.
- Use disposable EC2 instances.
- Do not modify shared security groups.
- Keep inbound SSH closed.
- Limit application access to the client security group.
- Verify resource ownership before cleanup.
- Do not grant inbound TCP 8080 to `0.0.0.0/0`.
- Terminate both instances after completing the lab.

### Cost Considerations

The lab uses two EC2 instances, EBS root volumes, and public IPv4 addresses.

No NAT gateway or paid interface endpoint is created.

---

## 5. Prepare the AWS Environment

Run in Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab04"

export VPC_CIDR="10.40.0.0/16"
export SUBNET_CIDR="10.40.1.0/24"

export VPC_NAME="cloud-lab04-vpc"
export SUBNET_NAME="cloud-lab04-subnet"
export IGW_NAME="cloud-lab04-igw"
export RT_NAME="cloud-lab04-rt"

export CLIENT_SG_NAME="cloud-lab04-client-sg"
export SERVER_SG_NAME="cloud-lab04-server-sg"

export CLIENT_NAME="cloud-lab04-client"
export SERVER_NAME="cloud-lab04-server"

export ROLE_NAME="cloud-lab04-ssm-role"
export PROFILE_NAME="cloud-lab04-ssm-profile"

export APP_PORT="8080"
```

Verify identity:

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

### Step 3 — Check Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create another VPC if an existing Lab 04 VPC needs to be reused or cleaned up.

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

## 7. Create the Subnet

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

The instances will explicitly receive public IPv4 addresses at launch for Systems Manager connectivity.

The client-to-server traffic will use only private IPv4 addresses.

---

## 8. Create Internet Gateway and Route Table

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Attach Gateway

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
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

### Step 5 — Associate Route Table

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
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
10.40.0.0/16 → local
0.0.0.0/0    → Internet Gateway
```

---

## 9. Create the Client and Server Security Groups

### Step 1 — Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab04 HTTP client security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Server Security Group

```bash
export SERVER_SG_ID=$(aws ec2 create-security-group \
  --group-name "$SERVER_SG_NAME" \
  --description "Lab04 HTTP server security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SERVER_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Both Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" "$SERVER_SG_ID" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Initial expected configuration:

| Group | Inbound | Outbound |
|---|---|---|
| Client SG | No rules | Allow all |
| Server SG | No rules | Allow all |

**Do not add the server TCP 8080 rule yet.** Its absence is the fault being investigated.

---

## 10. Configure IAM for Session Manager

### Step 1 — Create Trust Policy

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

### Step 2 — Create IAM Role

Check that the role and instance profile names are unused.

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Then create the role if absent:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach Systems Manager Permissions

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

### Step 5 — Associate Role With Profile

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

Allow for IAM propagation before launching instances.

---

## 11. Configure the HTTP Server

Create a file named `server-user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

mkdir -p /opt/vpc-lab04

cat > /opt/vpc-lab04/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>VPC Lab 04</title></head>
<body>
<h1>VPC LAB 04 - HTTP SERVER WORKING</h1>
<p>Security group troubleshooting test.</p>
</body>
</html>
HTML

cat > /etc/systemd/system/vpc-lab04-web.service <<'UNIT'
[Unit]
Description=VPC Lab 04 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/vpc-lab04
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

chmod 755 /opt/vpc-lab04
chmod 644 /opt/vpc-lab04/index.html
chmod 644 /etc/systemd/system/vpc-lab04-web.service

systemctl daemon-reload
systemctl enable --now vpc-lab04-web.service
```

### Purpose of the Script

The user-data script:

1. Creates a directory for the HTTP application.
2. Writes a simple HTML page.
3. Creates a systemd service.
4. Starts a Python HTTP server on port `8080`.
5. Configures the service to restart after certain failures.

The server listens on all instance interfaces, but the security group controls whether remote clients can connect.

---

## 12. Launch the EC2 Instances

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Lab Instances

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

### Step 3 — Launch the Server Instance

```bash
export SERVER_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SERVER_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://server-user-data.sh \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$SERVER_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch the Client Instance

```bash
export CLIENT_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
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

### Step 7 — Verify Systems Manager Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$SERVER_ID,$CLIENT_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both managed nodes eventually show `Online`.

---

## 13. Reproduce the Security Group Failure

### Step 1 — Connect to the Server

Use EC2 Console → Instances → Connect → Session Manager, or:

```bash
aws ssm start-session \
  --target "$SERVER_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify HTTP Service Status

Inside the server:

```bash
sudo systemctl status vpc-lab04-web.service --no-pager
```

Expected: `active (running)`.

### Step 3 — Check Listening Port

```bash
sudo ss -lntp | grep ':8080'
```

Expected: the Python HTTP server is listening on TCP `8080`.

### Step 4 — Test Locally

```bash
curl -fsS --max-time 5 http://127.0.0.1:8080/
```

Expected:

```html
<h1>VPC LAB 04 - HTTP SERVER WORKING</h1>
```

If the service fails, inspect:

```bash
sudo journalctl -u vpc-lab04-web.service -n 40 --no-pager
sudo tail -n 60 /var/log/cloud-init-output.log
```

Confirm the web application works locally before investigating security groups.

Exit:

```bash
exit
```

### Step 5 — Connect to the Client

From WSL2:

```bash
aws ssm start-session \
  --target "$CLIENT_ID" \
  --region "$AWS_REGION"
```

Inside the client, enter the server private IP obtained earlier:

```bash
export SERVER_PRIVATE_IP="10.40.1.REPLACE"
```

### Step 6 — Attempt HTTP Connection

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 8 \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected: TCP connection timeout.

Example:

```text
curl: (28) Failed to connect to 10.40.1.x port 8080
```

The timeout is expected because the server security group has no inbound TCP 8080 allow rule.

Exit:

```bash
exit
```

---

## 14. Troubleshooting Investigation

### Check 1 — Inspect Server Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SERVER_SG_ID" \
  --query 'SecurityGroups[0].{Group:GroupId,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
{
  "Inbound": []
}
```

This is the primary finding.

### Check 2 — Inspect Client Egress

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

Expected: outbound traffic allowed.

### Check 3 — Verify Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Traffic between `10.40.1.x` instances uses the VPC-local route.

The internet gateway is not involved in this application connection.

### Check 4 — Inspect Network ACL

```bash
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Rules:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the newly created VPC's default NACL permits the test traffic.

### Check 5 — Confirm Web Application Is Running

If needed, reconnect to the server:

```bash
sudo systemctl is-active vpc-lab04-web.service
sudo ss -lntp | grep ':8080'
curl -fsS http://127.0.0.1:8080/
```

### Investigation Summary

| Component | Finding |
|---|---|
| Client EC2 | Running |
| Server EC2 | Running |
| Server application | Running |
| Local server request | Successful |
| VPC-local route | Present |
| Client SG outbound | Allowed |
| Server SG inbound | Missing TCP 8080 |
| Network ACL | Permits traffic |
| Client HTTP request | Timeout |
| Root cause | Missing server inbound security group rule |

---

## 15. Root Cause Analysis

### Root Cause

The security group attached to the server EC2 instance had no inbound rule permitting TCP 8080 from the client.

### Technical Explanation

The client initiates a TCP connection to the server's private IP address on port 8080.

Although the packet can be routed within the VPC, the destination security group does not contain an allow rule matching the requested traffic.

The connection is therefore blocked before reaching the web server.

### Root Cause Flow

```text
Client EC2
    |
    v
Outbound TCP 8080
    |
    v
VPC Local Route
    |
    v
Server Security Group
    |
    v
No Matching Inbound Allow Rule
    |
    X
Connection Times Out
```

### Five Whys

1. **Why couldn't the client connect?** The TCP connection timed out.
2. **Why was the connection blocked?** The server SG did not permit inbound TCP 8080.
3. **Why didn't the working VPC route solve it?** Routing and traffic authorization are separate controls.
4. **Why was the running server insufficient?** A listening application does not override security group restrictions.
5. **How can the issue be prevented?** Define and review application-specific SG rules in infrastructure as code and test connectivity after deployment.

---

## 16. Remediation

### Step 1 — Add a Least-Privilege Inbound Rule

From WSL2:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$CLIENT_SG_ID,Description=Allow-Lab04-client-HTTP}]" \
  --region "$AWS_REGION"
```

This permits TCP 8080 from members of the client security group.

### Step 2 — Verify the Inbound Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SERVER_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: tcp
Port: 8080
Source: CLIENT_SG_ID
```

### Step 3 — Reconnect to Client EC2

Use Session Manager.

Set the server private IP:

```bash
export SERVER_PRIVATE_IP="10.40.1.REPLACE"
```

### Step 4 — Retest Connectivity

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 8 \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected:

```html
<h1>VPC LAB 04 - HTTP SERVER WORKING</h1>
```

### Step 5 — Verify HTTP Status

```bash
curl -s -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  "http://${SERVER_PRIVATE_IP}:8080/"
```

Expected:

```text
HTTP Status: 200
```

Exit:

```bash
exit
```

### Optional — Verify the Rule Controls the Failure

From WSL2, revoke:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

Retest a new HTTP connection from the client; it should fail again.

Restore the rule:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$CLIENT_SG_ID,Description=Allow-Lab04-client-HTTP}]" \
  --region "$AWS_REGION"
```

Verify another new HTTP connection succeeds.

---

## 17. Verification Matrix

| Check | Failure State | Corrected State |
|---|---|---|
| Client EC2 running | Yes | Yes |
| Server EC2 running | Yes | Yes |
| HTTP server listening | Yes | Yes |
| Local HTTP test | Successful | Successful |
| VPC route | Valid | Valid |
| Client SG outbound | Allowed | Allowed |
| Server SG TCP 8080 inbound | Missing | Allowed from client SG |
| Client HTTP request | Timeout | Successful |
| HTTP status | Unavailable | 200 |
| Unrestricted public application access | No | No |

### Success Criteria

The incident is resolved when:

- Both instances are healthy.
- The web server responds locally.
- The server SG permits TCP 8080 from the client SG.
- The client can access the server's private IPv4 address.
- HTTP returns status `200`.
- The rule does not permit unrestricted internet access.

---

## 18. Production Best Practices

### Security Group Design

- Use security group references when possible.
- Allow only required application ports.
- Avoid `0.0.0.0/0` for internal application services.
- Maintain separate security groups for different application roles.
- Review both inbound and outbound rules.
- Remove unused security group rules.
- Document the business purpose of each rule.

### Troubleshooting Best Practices

- Verify the application is listening before changing networking rules.
- Check the source and destination security groups.
- Confirm the correct source private IP or source SG.
- Check the VPC-local route.
- Inspect network ACLs.
- Verify operating-system firewall behavior if needed.
- Test connectivity from the actual source instance.
- Verify the original application request after remediation.

### Prevention

For production, use infrastructure as code and code review to manage rules.

A connectivity test can also be part of a deployment validation pipeline.

VPC Flow Logs and Reachability Analyzer can provide additional troubleshooting evidence when necessary.

---

## 19. Interview Questions and Answers

### Q1. What is an AWS security group?

A stateful virtual firewall associated with AWS network interfaces.

### Q2. Can security groups explicitly deny traffic?

No. Security group rules allow matching traffic. Traffic that has no matching allow rule is blocked.

### Q3. What is the difference between a security group and a network ACL?

Security groups are stateful and work at the network interface level. Network ACLs are stateless and work at subnet boundaries.

### Q4. Why did the HTTP request time out?

The server security group had no inbound allow rule for TCP 8080 from the client.

### Q5. Why did the web server respond on localhost?

Localhost communication does not require the client-to-server network connection that was blocked by the destination security group.

### Q6. Why didn't the VPC-local route solve the issue?

Routing determines where traffic goes. Security groups determine whether the traffic is permitted.

### Q7. Why use a security group reference instead of a CIDR?

A source security group limits access to network interfaces associated with that group, rather than allowing a broader IP address range.

### Q8. Does the client need an inbound ephemeral-port rule?

No. Security groups are stateful, so established return traffic is automatically permitted.

### Q9. Does opening port 8080 on the security group start the application?

No. The application must already be listening on the destination port.

### Q10. Can two EC2 instances in the same subnet still fail to communicate?

Yes. Security group rules, host firewall settings, applications, and other configuration problems can block communication.

### Q11. What AWS command adds a security group inbound rule?

`aws ec2 authorize-security-group-ingress`

### Q12. How would you explain this incident in an interview?

> I created two EC2 instances in an isolated AWS VPC. One instance hosted a Python HTTP server on port 8080, while the other acted as the HTTP client. I intentionally left the server security group without an inbound allow rule. I verified the server was running and listening locally, but the client connection timed out. After examining routing, security groups, and network ACLs, I identified the missing server inbound rule. I added a rule allowing TCP 8080 specifically from the client security group and confirmed the HTTP request returned status 200. Finally, I cleaned up the temporary infrastructure.

---

## 20. Cleanup

**Warning:** Verify account identity and lab tags before deleting resources. These commands are intended only for resources created in Lab 04.

### Step 1 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify VPC and Instance Tags

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `Project=VPC-Troubleshooting-Lab04`.

### Step 3 — Verify Root Volume Deletion Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.{Volume:VolumeId,DeleteOnTermination:DeleteOnTermination}' \
  --output table \
  --region "$AWS_REGION"
```

Record the root EBS volume IDs for later verification.

### Step 4 — Terminate Both Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$CLIENT_ID" "$SERVER_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Remove the Server Inbound Rule

If it is present:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$SERVER_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

If the rule was already removed, skip the command.

### Step 6 — Check Network Interface Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Proceed when the lab instances' network interfaces have been removed.

### Step 7 — Delete the Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$SERVER_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Confirm the IAM resources belong exclusively to Lab 04 and the instance profile is not used by another active instance.

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

### Step 10 — Delete the Custom Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

Do not delete the VPC's main route table manually.

### Step 11 — Delete the Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Remove the Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete the Dedicated VPC

After verifying no other resources depend on the VPC:

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Final Verification

Check for remaining active lab instances:

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

Verify that both EC2 root EBS volumes were deleted.

### Cleanup Summary

| Resource | Expected Outcome |
|---|---|
| Client EC2 | Terminated |
| Server EC2 | Terminated |
| Root EBS volumes | Deleted |
| Client security group | Deleted |
| Server security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Custom route table | Deleted |
| Subnet | Deleted |
| Internet gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
04-security-group-blocks-traffic/
├── README.md
├── ec2-trust-policy.json
└── server-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Full troubleshooting documentation |
| `ec2-trust-policy.json` | EC2 IAM trust relationship for Session Manager |
| `server-user-data.sh` | Creates and starts the test Python HTTP server |

Do not commit AWS credentials, SSH private keys, or sensitive account information.

---

## 22. Lessons Learned

This lab demonstrated how network communication between EC2 instances can fail even when both instances are running and their VPC routing configuration is correct.

The server was listening on TCP port 8080 and successfully responded to localhost requests.

However, the client couldn't connect because the destination security group lacked a matching inbound allow rule.

The investigation showed why it is important to separate application problems, routing problems, and security filtering problems.

By adding a restricted inbound rule referencing the client security group, we restored HTTP connectivity without exposing the application to the entire internet.

**Key Lesson:** A healthy application and correct VPC route do not guarantee connectivity. The destination security group must explicitly permit the intended connection.

---

## 23. Skills Demonstrated

- Amazon VPC networking
- EC2-to-EC2 communication
- Stateful security group troubleshooting
- Security group references
- Least-privilege network access
- TCP connectivity diagnostics
- Linux network socket inspection
- Python HTTP server deployment
- EC2 user-data configuration
- Systems Manager Session Manager
- AWS CLI v2
- Root cause analysis
- Incident remediation
- Verification and cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-004 |
| Problem | Client cannot reach EC2 web server |
| Application Port | TCP 8080 |
| Server Process | Running |
| Root Cause | Missing inbound server SG rule |
| Remediation | Allow TCP 8080 from client SG |
| Network Exposure | Restricted to client SG |
| HTTP Response After Fix | 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When communication between EC2 instances fails, confirm that the application is listening, inspect the destination security group, and test the connection from the actual source. Apply a narrowly scoped allow rule and verify the service responds successfully.
