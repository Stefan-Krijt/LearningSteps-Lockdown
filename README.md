# LearningSteps: Zero-Trust Cloud Security Architecture

## Project Overview
This repository contains a fully automated, immutable deployment of the LearningSteps API (a FastAPI + PostgreSQL application). 

Starting from an intentionally vulnerable baseline, this project implements a comprehensive, end-to-end security architecture following the Zero Trust principle. The entire infrastructure—from the network layer to the application identity layer—is codified in Terraform and automated via cloud-init.

## Architecture & Security Controls

This deployment implements Defense in Depth across five critical layers:

### 1. Identity & Access Management
- Entra ID SSH: Static SSH keys have been replaced with identity-based access. Administrators log in using their corporate Entra ID credentials via az ssh, complete with MFA and full audit trails.
- OAuth2-Proxy (Identity Gate): Anonymous access to the API is completely blocked. All traffic is intercepted by an OAuth2-Proxy sidecar that enforces Microsoft Entra ID authentication via JWT tokens before requests reach the FastAPI application.

### 2. Network Security
- NSG Lockdown: Management access (SSH) is restricted to a trusted IP address via Network Security Groups.
- VNet Integration: The PostgreSQL database is deployed into a delegated private subnet (snet-db) with no public IP. It is completely invisible to the internet.
- Micro-segmentation: A dedicated NSG on the database subnet only allows traffic on port 5432 from the application subnet, preventing lateral movement.
- Private DNS: A Private DNS Zone (privatelink.postgres.database.azure.com) handles internal routing.

### 3. Data & Secret Protection
- TLS Encryption: All public traffic is encrypted via Let's Encrypt TLS certificates managed by NPMplus.
- Zero Plaintext Secrets: The VM's disk contains no passwords. The application and the OAuth2 proxy use the VM's System-Assigned Managed Identity to fetch database credentials and OAuth2 client secrets directly from Azure Key Vault at runtime. Secrets exist only in RAM.

### 4. Application Security
- WAF (Web Application Firewall): CrowdSec is deployed at the edge to inspect payloads and block SQL injection and XSS attacks before they reach the application.
- Rate Limiting: Nginx limit_req is configured to prevent API scraping and Layer 7 Denial of Service (DoS) attacks.

### 5. Automation & Immutable Infrastructure
- cloud-init: The entire VM stack (Docker, NPMplus, OAuth2-Proxy, FastAPI) is automatically provisioned on first boot.
- Race Condition Mitigation: The cloud-init script masks apt-daily timers and uses fuser to wait for package locks, ensuring reliable, hands-off deployments.
- Terraform: 100% of the Azure infrastructure is managed as code.

## Deployment Guide

### Prerequisites
- Terraform >= 1.5
- Azure CLI (az)
- Python 3.8+
- A terraform.tfvars file containing your db_admin_password and my_ip (this file is gitignored to prevent secret leakage).

### 1. Deploy Infrastructure
Run the following commands:

terraform init
terraform apply

Wait ~8-10 minutes for the VM to boot and cloud-init to finish provisioning.

### 2. Configure Edge Routing (One-time)
Because NPMplus stores its routing state in a local SQLite database, the initial Proxy Host must be created via the API after the VM is up. 
See the hardening-log.md for the exact API commands to create the Proxy Host, request the Let's Encrypt certificate, and bind it.

### 3. Access the Application
Navigate to your Azure FQDN (e.g., https://learningsteps-lokiyn.westeurope.cloudapp.azure.com). You will be redirected to Microsoft Entra ID to authenticate before seeing the Swagger API documentation.

## Documentation
For a complete, day-by-day breakdown of the threat model, implementation steps, and troubleshooting (including real-world limits discovered with self-hosted WAFs), please refer to the hardening-log.md file in this repository.