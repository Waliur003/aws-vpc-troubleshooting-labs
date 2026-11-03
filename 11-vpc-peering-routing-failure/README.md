# Lab 11 — VPC Peering Routing Failure

## Overview

This lab demonstrates how to troubleshoot an AWS VPC peering connectivity failure caused by a missing return route.

We create two AWS VPCs with non-overlapping CIDR blocks, establish a VPC peering connection, and deploy two EC2 instances.

VPC A hosts a client EC2 instance, while VPC B hosts a Python HTTP server on port 8080.

Initially, the client can communicate with the server using its private IPv4 address. We then intentionally remove VPC B's route back to VPC A.

Although the peering connection remains active and the HTTP server continues running, client requests fail because response traffic cannot return through the peering connection.

We investigate the problem, restore the missing route, verify communication, and clean up the resources.

**Troubleshooting workflow:**

Provision → Establish Baseline → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-VPC-011 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | VPC, EC2, VPC Peering, IAM, Systems Manager |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, Python |
| VPC A CIDR | `10.110.0.0/16` |
| VPC B CIDR | `10.120.0.0/16` |
| VPC A Subnet | `10.110.1.0/24` |
| VPC B Subnet | `10.120.1.0/24` |
| VPC A Workload | Client EC2 |
| VPC B Workload | HTTP Server EC2 |
| Test Protocol | HTTP, TCP 8080 |
| Peering Connection | Same-region VPC peering |
| Simulated Failure | Missing VPC B return route |
| Root Cause | Incorrect peering return routing |
| Remediation | Restore VPC B route to VPC A |
| Verification | Successful HTTP request over private IP |
| Management | AWS Systems Manager Session Manager |

---

## 2. Production Incident Scenario

A company operates an application across two AWS VPCs.

VPC A contains application clients. VPC B contains a backend service.

The engineering team establishes VPC peering so that both environments can communicate privately.

Initially, the application can successfully reach the backend.

Following a network configuration change, requests from VPC A to VPC B begin timing out.

The engineer investigates and discovers:

- Both VPCs exist.
- The VPC peering connection is active.
- Both EC2 instances are running.
- The backend HTTP service is running.
- VPC A has a correct route to VPC B.
- Security groups permit the required traffic.
- Network ACLs are correctly configured.
- VPC B has no route back to VPC A.
- HTTP requests from the client time out.

### Expected Behavior

```text
Client EC2 — VPC A
        |
        v
VPC A Route Table
10.120.0.0/16 → Peering
        |
        v
VPC Peering Connection
        |
        v
VPC B Route Table
        |
        v
Server EC2 — TCP 8080
        |
        v
Response via VPC B Return Route
10.110.0.0/16 → Peering
        |
        v
Client Receives HTTP 200
```

### Failure Behavior

```text
Client EC2 — VPC A
        |
        v
VPC A → VPC B
        |
        v
Server Receives Traffic
        |
        v
Server Sends Response
        |
        X
VPC B Return Route Missing
        |
        X
Client Request Times Out
```

### Potential Business Impact

- Internal application APIs become unavailable.
- Backend service communication fails.
- Microservice requests time out.
- Internal application dependencies break.
- Cross-VPC data transfers fail.
- Application response times increase.
- Production incidents affect multiple services.

### Incident Objective

Identify why an active VPC peering connection cannot support successful application communication and restore the missing return route.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                  AWS Region: us-east-1

       +-------------------+     +-------------------+
       | VPC A             |     | VPC B             |
       | 10.110.0.0/16     |     | 10.120.0.0/16     |
       |                   |     |                   |
       | Client EC2        |     | HTTP Server EC2   |
       | 10.110.1.x        |     | 10.120.1.x        |
       |                   |     | TCP 8080          |
       |        |          |     |        ^          |
       |        v          |     |        |          |
       | Route Table A     |     | Route Table B     |
       |                   |     |                   |
       | Route to VPC B    |     | Route to VPC A    |
       | via Peering       |     | via Peering       |
       +--------|----------+     +--------|----------+
                |                         |
                +------ VPC Peering ------+
                       Connection
```

### Broken Architecture

```text
VPC A                                VPC B

Client EC2                           Server EC2
    |                                    ^
    v                                    |
Route to VPC B --------------------------+
    |
    |          Request can reach server
    |
    X <---------- Response cannot return

               Missing:
               10.110.0.0/16 → Peering
               in VPC B Route Table
```

### AWS Resources

| Resource | VPC A | VPC B |
|---|---|---|
| VPC CIDR | `10.110.0.0/16` | `10.120.0.0/16` |
| Subnet CIDR | `10.110.1.0/24` | `10.120.1.0/24` |
| EC2 workload | Client | HTTP server |
| Security group | Client SG | Server SG |
| Inbound application rule | None | TCP 8080 from client subnet |
| Default route | IGW A | IGW B |
| Peering route | To VPC B | To VPC A |
| Management | SSM | SSM |

Each VPC has its own Internet Gateway for Systems Manager access. Application traffic between the VPCs uses private IP addresses through the peering connection.

---

## 4. Understanding VPC Peering

VPC peering enables two VPCs to communicate privately through AWS networking.

Instances can communicate using private IPv4 addresses when their networking configuration permits the traffic.

### Important Characteristics

- Peering can connect VPCs in the same or different AWS Regions.
- VPCs must have non-overlapping IPv4 CIDR blocks.
- A peering connection must be accepted before use.
- Each VPC needs routes to the other VPC's address ranges.
- Security groups and NACLs must permit the traffic.
- VPC peering does not support transitive routing.
- An Internet Gateway is not required for peering communication.

### Why Two Routes Are Needed

Healthy VPC A route table:

```text
Destination        Target
10.110.0.0/16      local
10.120.0.0/16      pcx-xxxxxxxx
0.0.0.0/0          igw-xxxxxxxx
```

Healthy VPC B route table:

```text
Destination        Target
10.120.0.0/16      local
10.110.0.0/16      pcx-xxxxxxxx
0.0.0.0/0          igw-xxxxxxxx
```

The first peering route carries traffic from VPC A to VPC B.

The second route carries response traffic from VPC B back to VPC A.

### Missing Return Route

```text
VPC B Route Table

Destination        Target
10.120.0.0/16      local
0.0.0.0/0          igw-xxxxxxxx
```

Without the route to VPC A, return traffic cannot travel over the peering connection.

The Internet Gateway's default route is not a valid substitute for private peering communication.

### Active Peering Does Not Guarantee Connectivity

A peering connection can report `active` while the application cannot communicate because of missing routes, security groups, NACLs, or workload issues.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC permissions
- IAM permissions
- AWS Systems Manager access
- Git and GitHub

### Safety Requirements

- Use two dedicated lab VPCs.
- Do not modify the default VPC.
- Do not change production peering routes.
- Keep EC2 inbound SSH closed.
- Restrict server HTTP access to the client subnet.
- Verify route table ownership before injecting failures.
- Use the local AWS CLI to restore routing.
- Delete temporary resources when finished.

### Cost Considerations

The lab may incur charges for two EC2 instances, EBS volumes, public IPv4 addresses, and applicable network data transfer.

VPC peering itself does not have an hourly connection charge, but data transfer may be billed.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="VPC-Troubleshooting-Lab11"

export VPC_A_CIDR="10.110.0.0/16"
export VPC_B_CIDR="10.120.0.0/16"

export SUBNET_A_CIDR="10.110.1.0/24"
export SUBNET_B_CIDR="10.120.1.0/24"

export VPC_A_NAME="cloud-lab11-vpc-a"
export VPC_B_NAME="cloud-lab11-vpc-b"

export ROLE_NAME="cloud-lab11-ssm-role"
export PROFILE_NAME="cloud-lab11-ssm-profile"
```

Verify identity:

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

### Step 3 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Investigate any existing Lab 11 resources before provisioning duplicates.

---

## 7. Create Both VPCs

### Step 1 — Create VPC A

```bash
export VPC_A_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_A_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_A_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create VPC B

```bash
export VPC_B_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_B_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_B_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Enable DNS

```bash
for VPC_ID in "$VPC_A_ID" "$VPC_B_ID"; do

  aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-support \
    --region "$AWS_REGION"

  aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames \
    --region "$AWS_REGION"

done
```

### Step 4 — Create Subnet A

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_A_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab11-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Subnet B

```bash
export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_B_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$LAB_AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-lab11-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

---

## 8. Configure Internet Gateways and Route Tables

### Step 1 — Create Internet Gateway A

```bash
export IGW_A_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-lab11-igw-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query InternetGateway.InternetGatewayId \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Create Internet Gateway B

```bash
export IGW_B_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-lab11-igw-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query InternetGateway.InternetGatewayId \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Create Route Table A

```bash
export RT_A_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_A_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab11-rt-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Route Table B

```bash
export RT_B_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_B_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-lab11-rt-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Add Default Routes

```bash
aws ec2 create-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_A_ID" \
  --region "$AWS_REGION"

aws ec2 create-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_B_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Associate Subnets

```bash
export RT_A_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$RT_A_ID" \
  --subnet-id "$SUBNET_A_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export RT_B_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$RT_B_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 9. Establish VPC Peering

### Step 1 — Create Peering Request

```bash
export PCX_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "$VPC_A_ID" \
  --peer-vpc-id "$VPC_B_ID" \
  --tag-specifications \
  "ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=cloud-lab11-peering},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Accept Peering

```bash
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Verify State

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
active
```

### Step 4 — Configure Route A to VPC B

```bash
aws ec2 create-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_B_CIDR" \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Configure Route B to VPC A

```bash
aws ec2 create-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Both Route Tables

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" "$RT_B_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Both VPCs should have valid peering routes.

---

## 10. Configure Security Groups

### Step 1 — Create Client Security Group

```bash
export SG_A_ID=$(aws ec2 create-security-group \
  --group-name cloud-lab11-client-sg \
  --description "Lab11 EC2 client security group" \
  --vpc-id "$VPC_A_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-lab11-client-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Server Security Group

```bash
export SG_B_ID=$(aws ec2 create-security-group \
  --group-name cloud-lab11-server-sg \
  --description "Lab11 EC2 server security group" \
  --vpc-id "$VPC_B_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-lab11-server-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow HTTP from VPC A Subnet

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_B_ID" \
  --protocol tcp \
  --port 8080 \
  --cidr "$SUBNET_A_CIDR" \
  --region "$AWS_REGION"
```

### Security Group Configuration

| Security Group | Inbound | Outbound |
|---|---|---|
| Client SG | No inbound rules | Default allow |
| Server SG | TCP 8080 from `10.110.1.0/24` | Default allow |

---

## 11. Configure IAM and HTTP Server

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

Check role/profile names first:

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

Attach Systems Manager permissions:

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Create the instance profile:

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM changes to propagate.

### Step 3 — Create HTTP Server User Data

Create `server-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab11

cat > /opt/lab11/index.html <<'HTML'
VPC Peering Lab 11
Server: VPC B
Status: HTTP server reachable
Connection: Private VPC Peering
HTML

cat > /etc/systemd/system/lab11-http.service <<'UNIT'
[Unit]
Description=Lab 11 HTTP Test Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab11
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab11-http.service
```

This starts a small Python HTTP server on TCP port 8080 when EC2 boots.

---

## 12. Launch EC2 Instances

### Step 1 — Retrieve Amazon Linux AMI

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

Do not launch duplicate resources.

### Step 3 — Launch Client EC2 in VPC A

```bash
export INSTANCE_A_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_A_ID,Groups=$SG_A_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab11-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch Server EC2 in VPC B

```bash
export INSTANCE_B_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
  "DeviceIndex=0,SubnetId=$SUBNET_B_ID,Groups=$SG_B_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://server-user-data.sh \
  --count 1 \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab11-server},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Wait for Both Instances

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Record Private IP Addresses

```bash
export CLIENT_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_A_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

export SERVER_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_B_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "Client: $CLIENT_IP"
echo "Server: $SERVER_IP"
```

Expected:

```text
Client: 10.110.1.x
Server: 10.120.1.x
```

---

## 13. Establish Healthy VPC Peering Connectivity

### Step 1 — Check Systems Manager

```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm both lab instances are `Online`.

### Step 2 — Verify HTTP Server

Connect to the server:

```bash
aws ssm start-session \
  --target "$INSTANCE_B_ID" \
  --region "$AWS_REGION"
```

Inside server EC2:

```bash
sudo systemctl status lab11-http.service --no-pager
```

Test:

```bash
curl --noproxy '*' -sS \
  --connect-timeout 3 \
  http://127.0.0.1:8080/
```

Expected:

```text
VPC Peering Lab 11
Server: VPC B
Status: HTTP server reachable
Connection: Private VPC Peering
```

Exit Session Manager.

### Step 3 — Test Client to Server

Connect to client EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_A_ID" \
  --region "$AWS_REGION"
```

Set the server's actual private IP:

```bash
export SERVER_IP="10.120.1.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: HTTP 200 and the test page.

### Step 4 — Create Background Monitoring

Inside the client EC2:

```bash
sudo tee /usr/local/bin/lab11-probe.sh > /dev/null <<'EOF'
#!/bin/bash

SERVER_IP="$1"
LOG="/var/tmp/vpc-lab11-probe.log"

for i in $(seq 1 90); do

  printf '%s ' "$(date -u +%FT%TZ)" >> "$LOG"

  if curl --noproxy '*' -fsS \
     --connect-timeout 3 \
     --max-time 5 \
     "http://${SERVER_IP}:8080/" \
     -o /dev/null; then

    echo "PEERING_HTTP=SUCCESS" >> "$LOG"

  else

    echo "PEERING_HTTP=FAILED" >> "$LOG"

  fi

  sleep 10

done
EOF
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/lab11-probe.sh
```

Start the recorder:

```bash
sudo systemd-run \
  --unit=lab11-probe \
  --collect \
  /usr/local/bin/lab11-probe.sh "$SERVER_IP"
```

Verify:

```bash
sudo tail -n 10 /var/tmp/vpc-lab11-probe.log
```

Expected: `PEERING_HTTP=SUCCESS`.

Exit Session Manager.

---

## 14. Reproduce the Peering Routing Failure

### Step 1 — Verify VPC B Return Route

From WSL2:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_B_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Confirm `10.110.0.0/16` targets the peering connection.

### Step 2 — Remove the Return Route

```bash
aws ec2 delete-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

This is the intentional misconfiguration.

### Step 3 — Verify Route Removal

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_B_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.120.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

### Step 4 — Verify VPC A Route

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the route to VPC B remains.

### Step 5 — Verify Peering State

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
active
```

### Step 6 — Reproduce Client Failure

Connect to the client through Session Manager.

Use the server's actual private IPv4:

```bash
export SERVER_IP="10.120.1.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: connection timeout.

The request can travel toward VPC B, but the response cannot return through the peering connection.

### Step 7 — Review Logs

```bash
sudo tail -n 20 /var/tmp/vpc-lab11-probe.log
```

Expected:

```text
PEERING_HTTP=FAILED
```

Exit Session Manager.

---

## 15. Troubleshooting Investigation

### Check 1 — Peering Connection

```bash
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].Status.Code' \
  --output text \
  --region "$AWS_REGION"
```

Finding: `active`.

### Check 2 — VPC A Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Finding: valid peering route to VPC B.

### Check 3 — VPC B Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_B_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

Finding: missing return route to VPC A.

### Check 4 — Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_A_ID" "$SG_B_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: server security group permits TCP 8080 from the client subnet.

### Check 5 — Network ACLs

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_A_ID" \
  --query 'NetworkAcls[].Entries' \
  --output json \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_B_ID" \
  --query 'NetworkAcls[].Entries' \
  --output json \
  --region "$AWS_REGION"
```

Finding: default NACLs permit traffic.

### Check 6 — Instance Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --query 'InstanceStatuses[].{ID:InstanceId,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: EC2 instances remain healthy.

### Check 7 — Verify HTTP Server

Connect to the server EC2:

```bash
sudo systemctl is-active lab11-http.service
```

```bash
curl --noproxy '*' -sS \
  --connect-timeout 3 \
  http://127.0.0.1:8080/
```

Expected: HTTP server running and responding locally.

### Investigation Summary

| Component | Finding |
|---|---|
| VPC A | Healthy |
| VPC B | Healthy |
| Peering connection | Active |
| Client EC2 | Running |
| Server EC2 | Running |
| HTTP server | Running |
| Security groups | Correct |
| Network ACLs | Correct |
| VPC A route to B | Present |
| VPC B route to A | Missing |
| Root cause | Missing return route |

---

## 16. Root Cause Analysis

### Root Cause

VPC B's route table no longer contained a route to VPC A's CIDR through the peering connection.

### Technical Explanation

Successful TCP communication requires both forward and return network paths.

The client in VPC A sends a request toward the HTTP server in VPC B.

VPC A's route table correctly forwards the traffic through the peering connection.

However, when the server sends a response, VPC B has no peering route to the client's private address range.

The default Internet Gateway route does not replace the required VPC peering return route.

The response cannot return through the intended private connection, so the client's request times out.

### Root Cause Flow

```text
Client EC2 — VPC A
        |
        v
Peering Route to VPC B
        |
        v
Server EC2 — VPC B
        |
        v
Response Traffic
        |
        X
Missing Route to VPC A
        |
        X
HTTP Request Times Out
```

### Five Whys

1. **Why did the client request time out?** The response could not return to the client.
2. **Why could the response not return?** VPC B lacked the peering return route.
3. **Why was the active peering connection insufficient?** Peering requires correct routing in both directions.
4. **Why didn't the default route solve the problem?** The Internet Gateway is not an alternative path for this private peering traffic.
5. **How can this be prevented?** Manage peering routes through infrastructure as code, review changes, and test connectivity from both sides.

---

## 17. Remediation

### Step 1 — Restore VPC B Return Route

From WSL2:

```bash
aws ec2 create-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Restored Route

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_B_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.120.0.0/16 → local
10.110.0.0/16 → Peering Connection
0.0.0.0/0     → Internet Gateway
```

### Step 3 — Verify Client Connectivity

Connect to VPC A through Session Manager.

Use the server's actual private IPv4:

```bash
export SERVER_IP="10.120.1.REPLACE"
```

Run:

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${SERVER_IP}:8080/"
```

Expected: successful HTTP 200 and the server's test page.

### Step 4 — Review Monitoring Logs

```bash
sudo cat /var/tmp/vpc-lab11-probe.log
```

Illustrative successful experiment:

```text
PEERING_HTTP=SUCCESS
PEERING_HTTP=FAILED
PEERING_HTTP=FAILED
PEERING_HTTP=SUCCESS
```

The actual timestamps and output should be used as evidence rather than this illustrative result.

### Verification Matrix

| Check | Baseline | During Failure | After Fix |
|---|---|---|---|
| Peering state | Active | Active | Active |
| VPC A route | Present | Present | Present |
| VPC B return route | Present | Missing | Restored |
| HTTP server | Running | Running | Running |
| EC2 health | Healthy | Healthy | Healthy |
| Client HTTP request | Success | Timeout | Success |
| SSM management | Online | Online | Online |

### Success Criteria

The lab is considered successful when:

- Peering state is `active`.
- Both route tables have valid peer CIDR routes.
- Security groups permit the test traffic.
- The backend HTTP service is running.
- The client receives HTTP 200 using the server's private IPv4.
- Temporary resources are cleaned up.

---

## 18. Production Best Practices

### VPC Peering Troubleshooting Checklist

1. Verify the peering connection is active.
2. Confirm the VPC CIDRs do not overlap.
3. Identify the source and destination subnet route tables.
4. Check the source VPC route to the peer.
5. Check the destination VPC return route.
6. Verify route targets reference the correct peering connection.
7. Inspect security groups.
8. Check NACLs in both VPCs.
9. Confirm the destination service is running.
10. Test connectivity using private IPv4 addresses.
11. Use VPC Reachability Analyzer when appropriate.
12. Verify connectivity after remediation.

### Prevention

- Manage peering and routes with Terraform.
- Review routing changes through pull requests.
- Avoid manual changes to shared network infrastructure.
- Document VPC CIDR assignments.
- Monitor application connectivity between VPCs.
- Maintain least-privilege security group rules.
- Include forward and return route validation in deployment checks.
- Use consistent tags for network resources.

### VPC Peering vs. Transit Gateway

| Feature | VPC Peering | Transit Gateway |
|---|---|---|
| Architecture | Point-to-point | Centralized hub |
| Transitive routing | No | Yes, when configured |
| Route management | Routes in each VPC | VPC and TGW routes |
| Best for | Limited VPC connections | Larger multi-VPC networks |
| Hourly resource charges | No peering connection hourly charge | Attachment and processing charges can apply |
| Network design | Simpler for a few VPCs | More scalable for complex environments |

---

## 19. Interview Questions and Answers

### Q1. What is AWS VPC peering?

A networking connection that allows two VPCs to communicate using private IP addresses.

### Q2. Can two VPCs communicate immediately after peering becomes active?

Not necessarily. Both route tables and relevant network security controls must permit traffic.

### Q3. Why do both VPCs need routes?

Traffic needs a valid forward path and a valid return path.

### Q4. What causes a peering route to show `blackhole`?

A route target can become unavailable, for example when a peering connection is deleted or otherwise not usable.

### Q5. Does VPC peering require an Internet Gateway?

No. Peering communication uses AWS private networking.

### Q6. Can VPC peering connect overlapping IPv4 CIDRs?

No. AWS does not allow VPC peering between overlapping IPv4 address ranges.

### Q7. Does VPC peering support transitive routing?

No. A peering connection does not allow one VPC to automatically route traffic through another VPC to a third VPC.

### Q8. Can security groups block peering traffic?

Yes. Security group rules must allow the required application traffic.

### Q9. What is asymmetric routing?

A situation where traffic travels through different forward and return paths. Missing or incorrect return routing can cause communication failures.

### Q10. Why might a server respond locally but fail when accessed from another VPC?

Possible causes include missing routes, security group rules, NACL restrictions, or other network configuration problems.

### Q11. How does Lab 11 differ from Lab 10?

Lab 10 investigates an S3 Gateway Endpoint route table association. Lab 11 investigates missing return routing between two peered VPCs.

### Q12. How would you explain this lab in an interview?

> I created two AWS VPCs with non-overlapping CIDR blocks and established VPC peering. I deployed a client EC2 instance in VPC A and a Python HTTP server in VPC B. After verifying private connectivity, I intentionally removed VPC B's return route to VPC A. The peering connection remained active, and the server continued running, but HTTP requests timed out. I investigated the route tables, security groups, and network ACLs, identified the missing return route, restored it, and verified that HTTP connectivity recovered.

---

## 20. Cleanup

**Important:** Confirm the resources belong exclusively to `VPC-Troubleshooting-Lab11` before running destructive commands.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_B_ID" \
  --query 'Vpcs[].{ID:VpcId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids "$PCX_ID" \
  --query 'VpcPeeringConnections[0].{ID:VpcPeeringConnectionId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Verify instance tags:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Record Root Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Volumes:BlockDeviceMappings[].Ebs}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm that the root volumes are configured for deletion on termination.

### Step 3 — Terminate Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_A_ID" "$INSTANCE_B_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Peering Routes

```bash
aws ec2 delete-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_B_CIDR" \
  --region "$AWS_REGION"

aws ec2 delete-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

Skip any route already removed.

### Step 5 — Delete Peering Connection

```bash
aws ec2 delete-vpc-peering-connection \
  --vpc-peering-connection-id "$PCX_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Delete Security Groups

After verifying the EC2 network interfaces are removed:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$SG_B_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Disassociate Route Tables

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_A_ASSOC" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_B_ASSOC" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Custom Route Tables

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_B_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Internet Gateways

Detach:

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"

aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"
```

Delete:

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete IAM Resources

Verify role tags and that the instance profile is no longer used.

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Remove permissions:

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Delete:

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 12 — Verify Remaining Dependencies

```bash
for VPC_ID in "$VPC_A_ID" "$VPC_B_ID"; do

  aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output table \
    --region "$AWS_REGION"

done
```

### Step 13 — Delete Both VPCs

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Final Verification

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

Confirm the VPCs, peering connection, and root EBS volumes have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Client EC2 | Terminated |
| Server EC2 | Terminated |
| Root EBS volumes | Deleted |
| VPC peering connection | Deleted |
| Client security group | Deleted |
| Server security group | Deleted |
| Route table A | Deleted |
| Route table B | Deleted |
| Subnet A | Deleted |
| Subnet B | Deleted |
| Internet Gateway A | Deleted |
| Internet Gateway B | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| VPC A | Deleted |
| VPC B | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
11-vpc-peering-routing-failure/
├── README.md
├── ec2-trust-policy.json
└── server-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Infrastructure setup, failure simulation, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | EC2 IAM role trust policy |
| `server-user-data.sh` | Configures and starts the backend HTTP test server |

Do not commit credentials, private keys, or other sensitive information.

---

## 22. Lessons Learned

This lab demonstrates that an active VPC peering connection does not guarantee successful communication between instances.

The request path from VPC A to VPC B was correctly configured. However, VPC B did not have a valid route for the response traffic.

Even though both EC2 instances were running, security groups were correct, and the backend HTTP service was healthy, the client could not complete its HTTP request.

Restoring VPC B's peering route allowed the response traffic to return through the peering connection.

**Key Lesson:** Always verify the forward and return routes when troubleshooting AWS VPC peering connectivity. An active peering connection is only one part of a working network path.

---

## 23. Skills Demonstrated

- AWS VPC peering
- Multi-VPC networking
- Private IPv4 connectivity
- Route table configuration
- Forward and return route troubleshooting
- EC2 network diagnostics
- Security group configuration
- Network ACL investigation
- HTTP connectivity testing
- AWS CLI v2
- Systems Manager administration
- Linux systemd services
- Bash connectivity monitoring
- Root cause analysis
- Controlled fault injection
- Network incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-VPC-011 |
| Problem | Inter-VPC HTTP connectivity failure |
| Peering Connection | Active |
| Root Cause | Missing VPC B return route |
| EC2 Health | Healthy |
| HTTP Server | Running |
| Security Groups | Correct |
| Remediation | Restore route to VPC A |
| HTTP After Fix | Successful |
| Private Connectivity | Restored |
| Cleanup | Temporary resources deleted |
| Expected Incident Status | Resolved |

**Key Takeaway:** VPC peering requires valid routing in both directions. When one VPC lacks the return route, the peering connection can remain active while applications fail to communicate.
