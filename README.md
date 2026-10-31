# AWS VPC Troubleshooting Labs

**15 Hands-On Production-Style AWS Networking Troubleshooting Labs**

## Overview

This repository contains 15 hands-on Amazon Virtual Private Cloud (VPC) troubleshooting labs designed to develop practical AWS networking, cloud engineering, and cloud security engineering skills.

Each lab focuses on a realistic networking problem that cloud engineers may encounter in production environments.

The labs cover public and private subnet connectivity, route tables, security groups, network ACLs, NAT gateways, internet gateways, DNS resolution, VPC endpoints, VPC peering, VPC Flow Logs, Reachability Analyzer, and Multi-AZ networking.

The objective is not only to deploy AWS networking resources but also to **understand why networking fails, investigate the root cause, implement remediation, and verify that connectivity is restored**.

All exercises are designed around real AWS services, AWS CLI commands, Linux networking tools, and practical incident-response techniques.

---

## Repository Objectives

By completing these labs, the goal is to develop the ability to:

- Design and troubleshoot AWS VPC networking.
- Diagnose public and private subnet connectivity failures.
- Investigate route tables, gateways, security groups, and network ACLs.
- Understand stateful and stateless network filtering.
- Troubleshoot VPC endpoints and private connectivity.
- Analyze VPC Flow Logs and network traffic paths.
- Use AWS Reachability Analyzer to investigate connectivity.
- Identify networking misconfigurations and security risks.
- Apply least-privilege network access.
- Document root causes and remediation procedures.
- Clean up temporary AWS resources to control costs.

---

## AWS Networking Architecture

The following is a simplified example architecture used as a reference across several labs.

```text
                         Internet
                            |
                            |
                     Internet Gateway
                            |
                            |
                  +-------------------+
                  |      AWS VPC      |
                  |    10.0.0.0/16    |
                  |                   |
                  |  +-------------+  |
                  |  | Public      |  |
                  |  | Subnet      |  |
                  |  | 10.0.1.0/24 |  |
                  |  |             |  |
                  |  | EC2         |  |
                  |  | NAT Gateway |  |
                  |  +-------------+  |
                  |          |        |
                  |          |        |
                  |  +-------------+  |
                  |  | Private     |  |
                  |  | Subnet      |  |
                  |  | 10.0.2.0/24 |  |
                  |  |             |  |
                  |  | EC2         |  |
                  |  | Application |  |
                  |  +-------------+  |
                  |                   |
                  | Route Tables      |
                  | Security Groups   |
                  | Network ACLs      |
                  | VPC Endpoints     |
                  +-------------------+
```

### Networking Components

| Component | Purpose |
|---|---|
| VPC | Isolated virtual network in AWS |
| Public Subnet | Subnet with a route to an internet gateway |
| Private Subnet | Subnet without a direct internet gateway route |
| Internet Gateway | Supports communication between VPC resources and the internet |
| NAT Gateway | Provides outbound access for private subnet resources |
| Route Table | Determines network traffic routing |
| Security Group | Stateful virtual firewall |
| Network ACL | Stateless subnet-level network filtering |
| VPC Endpoint | Private connectivity to supported services |
| VPC Peering | Private connectivity between VPCs |
| VPC Flow Logs | Records network traffic metadata |
| Reachability Analyzer | Analyzes network paths and configuration |
| Route 53 VPC Resolver | Provides DNS resolution for VPC resources |

---

## Troubleshooting Labs

| Lab | Troubleshooting Scenario | Main Skills |
|---|---|---|
| [01](./01-public-subnet-no-internet/) | Public Subnet Cannot Access Internet | IGW, route table, public IP |
| [02](./02-private-subnet-internet-failure/) | Private Subnet Internet Failure | Private routing, NAT |
| [03](./03-incorrect-route-table/) | Incorrect Route Table | Route associations, destinations |
| [04](./04-security-group-blocks-traffic/) | Security Group Blocks Traffic | Stateful firewall rules |
| [05](./05-network-acl-blocks-traffic/) | Network ACL Blocks Traffic | Stateless filtering, ephemeral ports |
| [06](./06-nat-gateway-routing-failure/) | NAT Gateway Routing Failure | NAT state, private subnet routing |
| [07](./07-internet-gateway-misconfiguration/) | Internet Gateway Misconfiguration | IGW attachment, public routing |
| [08](./08-vpc-dns-resolution-disabled/) | VPC DNS Resolution Disabled | DNS attributes, resolver troubleshooting |
| [09](./09-vpc-endpoint-connectivity-failure/) | VPC Endpoint Connectivity Failure | Interface endpoints, private DNS |
| [10](./10-s3-gateway-endpoint-misconfiguration/) | S3 Gateway Endpoint Misconfiguration | Gateway endpoint routing, policies |
| [11](./11-vpc-peering-routing-failure/) | VPC Peering Routing Failure | Cross-VPC connectivity |
| [12](./12-overlapping-vpc-cidr-blocks/) | Overlapping VPC CIDR Blocks | IP planning, CIDR overlap |
| [13](./13-flow-logs-not-delivering/) | Flow Logs Not Delivering | Flow Logs, IAM, CloudWatch Logs |
| [14](./14-reachability-analyzer-investigation/) | Reachability Analyzer Investigation | Network path analysis |
| [15](./15-multi-az-network-connectivity-failure/) | Multi-AZ Network Connectivity Failure | AZ routing, high availability |

**Note:** Individual lab folders and detailed READMEs will be added as each hands-on exercise is completed.

---

## Repository Structure

```text
aws-vpc-troubleshooting-labs/
│
├── README.md
│
├── 01-public-subnet-no-internet/
│   └── README.md
│
├── 02-private-subnet-internet-failure/
│   └── README.md
│
├── 03-incorrect-route-table/
│   └── README.md
│
├── 04-security-group-blocks-traffic/
│   └── README.md
│
├── 05-network-acl-blocks-traffic/
│   └── README.md
│
├── 06-nat-gateway-routing-failure/
│   └── README.md
│
├── 07-internet-gateway-misconfiguration/
│   └── README.md
│
├── 08-vpc-dns-resolution-disabled/
│   └── README.md
│
├── 09-vpc-endpoint-connectivity-failure/
│   └── README.md
│
├── 10-s3-gateway-endpoint-misconfiguration/
│   └── README.md
│
├── 11-vpc-peering-routing-failure/
│   └── README.md
│
├── 12-overlapping-vpc-cidr-blocks/
│   └── README.md
│
├── 13-flow-logs-not-delivering/
│   └── README.md
│
├── 14-reachability-analyzer-investigation/
│   └── README.md
│
└── 15-multi-az-network-connectivity-failure/
    └── README.md
```

Additional files such as Terraform configurations, Bash scripts, IAM policies, or network diagrams may be added when required by an individual lab.

---

## Troubleshooting Methodology

Each lab follows a consistent production-style incident investigation process.

### 1. Identify the Incident

Understand the application or networking symptom.

Examples:

- EC2 cannot access the internet.
- Private subnet cannot reach AWS services.
- Traffic is blocked between two instances.
- DNS resolution fails.
- VPC peering traffic cannot reach its destination.

### 2. Verify Baseline Configuration

Inspect the relevant AWS resources before changing anything.

Examples:

```bash
aws ec2 describe-vpcs
aws ec2 describe-subnets
aws ec2 describe-route-tables
aws ec2 describe-security-groups
```

### 3. Reproduce the Problem

Use a dedicated disposable environment to reproduce an intentional misconfiguration.

Avoid introducing failures in shared or production infrastructure.

### 4. Investigate

Use AWS CLI and Linux commands to investigate networking behavior.

Typical commands:

```bash
ip route
ip addr
getent hosts example.com
curl -I https://example.com
```

Depending on the lab, additional tools may include:

```bash
ss
dig
traceroute
tcpdump
```

These tools will be installed or used only when appropriate and supported by the test environment.

### 5. Identify the Root Cause

Determine whether the failure originates from:

- Routing
- Security group rules
- Network ACL rules
- Gateway configuration
- DNS settings
- VPC endpoints
- Network address conflicts
- IAM permissions
- AWS service configuration

### 6. Apply Remediation

Correct the specific configuration responsible for the problem.

Use the least disruptive change necessary.

### 7. Verify Recovery

Repeat the original connectivity test.

Compare the working state against the failure state.

### 8. Cleanup

Remove temporary resources and confirm that shared AWS infrastructure remains unchanged.

---

## Tools and Technologies

| Category | Technologies |
|---|---|
| Cloud Provider | Amazon Web Services |
| Cloud Networking | Amazon VPC |
| Compute | Amazon EC2 |
| Routing | Route Tables, IGW, NAT Gateway |
| Security | Security Groups, Network ACLs |
| Private Connectivity | VPC Endpoints, VPC Peering |
| DNS | Route 53 VPC Resolver |
| Monitoring | VPC Flow Logs, CloudWatch Logs |
| Network Analysis | AWS Reachability Analyzer |
| Command Line | AWS CLI v2 |
| Operating System | Ubuntu WSL2, Amazon Linux |
| Scripting | Bash |
| Version Control | Git and GitHub |
| Optional IaC | Terraform |

---

## Prerequisites

Before starting, ensure you have:

1. An AWS account with appropriate permissions.
2. AWS CLI v2 configured.
3. Ubuntu WSL2 or another compatible Linux environment.
4. Basic understanding of IP addressing and CIDR notation.
5. Familiarity with Linux command-line operations.
6. Git and GitHub.
7. Permissions to create and remove temporary AWS networking resources.

Verify AWS CLI:

```bash
aws --version
```

Verify credentials:

```bash
aws sts get-caller-identity
```

Set a default region if appropriate:

```bash
export AWS_REGION="us-east-1"
```

---

## AWS Cost Management

Some networking resources can incur charges even when they are not actively processing traffic.

Examples include:

- NAT gateways
- Interface VPC endpoints
- Public IPv4 addresses
- EC2 instances
- CloudWatch Logs ingestion and storage
- Reachability Analyzer analyses

To minimize unnecessary expenses:

- Create only the resources needed for the current lab.
- Avoid leaving NAT gateways running after testing.
- Delete interface endpoints when no longer needed.
- Terminate disposable EC2 instances.
- Remove unused Elastic IP allocations.
- Review remaining CloudWatch log resources.
- Confirm that shared networking resources are preserved.

Use AWS Budgets or another suitable cost-monitoring method.

**Important:** All destructive actions must target only resources created for the specific lab.

---

## Security Best Practices

The labs follow a security-focused troubleshooting approach.

- Apply least-privilege IAM permissions.
- Avoid unrestricted inbound SSH access.
- Use Session Manager where appropriate.
- Limit security group rules to required traffic.
- Understand both ingress and egress filtering.
- Avoid overly permissive network ACL changes.
- Prefer private service connectivity when appropriate.
- Use VPC Flow Logs to support network investigations.
- Protect production VPC configurations.
- Document changes and recovery procedures.

---

## Expected Learning Outcomes

After completing the 15 labs, the goal is to confidently troubleshoot:

| Domain | Expected Ability |
|---|---|
| Public networking | Identify missing internet access |
| Private networking | Diagnose NAT and route issues |
| Routing | Correct destination and route-target mistakes |
| Security groups | Identify blocked traffic |
| Network ACLs | Troubleshoot stateless traffic filtering |
| DNS | Investigate VPC DNS failures |
| VPC endpoints | Restore private service connectivity |
| VPC peering | Diagnose cross-VPC routing |
| CIDR planning | Recognize overlapping address spaces |
| Flow Logs | Investigate delivery configuration |
| Reachability Analyzer | Analyze network paths |
| Multi-AZ networking | Diagnose cross-AZ connectivity problems |

---

## Interview Preparation

These labs are intended to help answer practical cloud engineering and cloud security engineering interview questions, including:

**Q1. An EC2 instance in a public subnet cannot access the internet. What would you check?**

Inspect the instance's public IP configuration, subnet route table, internet gateway, security group, network ACL, and operating-system settings.

**Q2. Why does a private EC2 instance need a NAT gateway?**

A NAT gateway is one way for private IPv4 workloads to initiate outbound internet connections without allowing unsolicited inbound internet connections.

**Q3. What is the difference between security groups and network ACLs?**

Security groups are stateful and associated with network interfaces. Network ACLs are stateless and applied at subnet boundaries.

**Q4. Why might VPC peering traffic fail?**

Possible causes include missing routes, blocked security rules, overlapping address ranges, or incorrect application and DNS configuration.

**Q5. What is AWS Reachability Analyzer?**

It is an AWS network analysis tool that examines supported network configurations to determine whether a path is reachable and identify potential blocking components.

**Q6. Why are VPC Flow Logs useful?**

They provide network traffic metadata that can assist with connectivity troubleshooting, monitoring, and security investigations.

---

## Documentation Format

Each individual lab README will contain:

1. Incident overview
2. AWS architecture
3. Prerequisites
4. Environment setup
5. Intentional failure simulation
6. AWS CLI investigation
7. Root cause analysis
8. Remediation steps
9. Verification
10. Production engineering considerations
11. Cleanup procedures
12. Interview questions and answers
13. Skills demonstrated
14. Expected incident outcome

Every lab will be documented separately, with runnable commands and explanations.

---

## Project Purpose

This repository is part of a practical learning portfolio focused on AWS cloud engineering, cloud networking, infrastructure troubleshooting, and cloud security engineering.

The objective is to develop hands-on incident-response abilities rather than relying only on theoretical networking knowledge or certifications.

The repository is designed to demonstrate familiarity with realistic AWS networking failures, structured troubleshooting, root cause analysis, and safe remediation practices.

## Final Goal

Build a documented collection of 15 AWS VPC troubleshooting exercises that demonstrate the ability to investigate networking incidents, restore connectivity, and apply secure cloud infrastructure practices.

**Core Principle: Identify the failure, understand the network path, fix the root cause, verify connectivity, and document the result.**
