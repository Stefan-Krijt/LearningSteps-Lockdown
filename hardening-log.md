# LearningSteps Hardening Log

## Day 0: Baseline Verification

**Goal:** Verify the app is running internally but not exposed publicly, establishing a known-good starting point.

**Verification:**
- SSH'd into the VM and confirmed `cloud-init` was `done`.
- Checked internal app health: `curl http://localhost:8000` returned `307` (FastAPI alive).
- Checked external access: `curl https://<domain>` failed (App is NOT publicly exposed).
- **Conclusion:** Baseline healthy. The "Gap" (no public access) exists.

---

## Day 1: Secure Management Access

**Goal:** Replace static SSH keys with identity-based login and restrict network access to the VM's management port.

### 1. Identity-Based SSH (Entra ID)
**The Gap:** The VM used a static SSH key (`.learningsteps_key`), which lacks MFA, rotation, and audit trails.
**Implementation:** 
Assigned the `Virtual Machine Administrator Login` RBAC role to my Entra ID identity, scoped directly to the VM.
**Verification:** 
- Successfully logged in using `az ssh vm --resource-group <rg> --name <vm-name>`.
- Confirmed OS-level authorization is now tied to corporate identity with Entra ID audit trails.

### 2. Restrict Management Perimeter (NSG)
**The Gap:** The NSG `allow-ssh` rule was open to `*` (the entire internet) on port 22.
**Implementation:**
- Defined a new variable `my_ip` in `variables.tf`.
- Updated `network.tf` to restrict the `allow-ssh` rule's `source_address_prefix` to `${var.my_ip}/32`.
- Defined the actual IP in `terraform.tfvars` (kept out of version control).
**Verification:**
- Ran `terraform apply` to enforce the rule via IaC.
- Confirmed the rule in the Azure Portal and successfully SSH'd in from the trusted IP.

### 3. Infrastructure Hardening (Secure Boot & vTPM)
**The Gap:** The base deployment did not enforce hardware-level boot security.
**Implementation:**
- Updated `vm.tf` to enforce `secure_boot_enabled = true` and `vtpm_enabled = true` (Trusted Launch).
- Because these settings require a VM replacement, I updated `scripts/cloud-init.yaml` to ensure all software is installed immutably on boot (detailed in Day 2, Section 0).
- Executed `terraform apply` to recreate the VM with Trusted Launch enabled.
**Verification:**
- Confirmed the VM successfully rebuilt and booted with Secure Boot and vTPM active.

---

## Day 2: Safe Public Exposure (TLS & WAF)

**Goal:** Expose the application securely using a reverse proxy with TLS, and protect it with a Web Application Firewall.

### 0. Automation Fix (Addressing `cloud-init` Failures)
**The Gap:** During initial deployment, the provided `cloud-init` script failed to install Docker and NPMplus, requiring manual installation. 
**Implementation:** 
- Updated `scripts/cloud-init.yaml` to install Docker CE, Docker Compose V2, NPMplus, and CrowdSec automatically on first boot.
- This eliminates configuration drift and ensures the infrastructure is truly immutable.

### 1. Reverse Proxy & TLS (NPMplus)
**The Gap:** The application had no public entry point, and no traffic encryption.
**Implementation:**
- Accessed the NPMplus Admin Panel via an SSH tunnel.
- Generated a Let's Encrypt TLS certificate for the Azure FQDN.
- Created a Proxy Host routing `https://<domain>` to `http://127.0.0.1:8000` with **Force HTTPS** enabled.
**Verification:**
- Executed `curl -i https://<domain>`.
- **Result:** `HTTP/2 307` with `location: /docs`. Traffic is encrypted and the app is publicly accessible.

### 2. Web Application Firewall (CrowdSec)
**The Gap:** The API was exposed to SQL injection and XSS payloads.
**Implementation:**
- Enabled the CrowdSec integration in the NPMplus `compose.yaml`.
- Generated a bouncer API key and configured NPMplus to communicate with CrowdSec.
- Installed the CrowdSec AppSec rules (OWASP CRS) for virtual patching.
**Verification:**
- Sent a simulated SQL injection payload: `curl -i "https://<domain>/?id=1%20OR%201=1"`.
- **Result:** The server returned a `<title>CrowdSec Ban</title>` HTML page, proving the WAF blocked the payload before it reached the FastAPI application.


## Day 3: Identity-Based API Access (OAuth2-Proxy)

**Goal:** Require a valid Entra ID identity token before any request reaches the application, replacing anonymous access with identity-based authentication.

**The Gap:** The API was publicly accessible. Anyone on the internet could read, write, or delete data without an audit trail or accountability.

**Implementation:**

### 1. Entra ID App Registration
- Created a dedicated Entra ID application registration (`learningsteps-oauth2-proxy-lokiyn`) using the Azure CLI.
- Configured the application manifest to use **v2.0 tokens** (`requestedAccessTokenVersion: 2`) to ensure compatibility with the OIDC proxy.
- Added the required Redirect URI for the OAuth2 callback: `https://<domain>/oauth2/callback`.
- Generated a Client Secret for the application.

### 2. OAuth2-Proxy Deployment
- Installed the `oauth2-proxy` binary on the VM (`/usr/local/bin/oauth2-proxy`).
- Created a systemd service (`/etc/systemd/system/oauth2-proxy.service`) running on `127.0.0.1:4180`.
- Configured the environment variables (`/etc/oauth2-proxy/oauth2-proxy.env`) with the Entra ID Client ID, Secret, and OIDC Issuer URL.
- Added specific startup flags to handle Entra ID token quirks:
  - `--oidc-email-claim=preferred_username` (Entra ID often omits the standard email claim).
  - `--insecure-oidc-allow-unverified-email=true` (Lab environment constraint).
  - `--whitelist-domain=.westeurope.cloudapp.azure.com` (Prevents redirect rejections).

### 3. NPMplus Identity Enforcement (Manual Override)
**The Issue:** NPMplus's built-in `oauth2proxy` Auth Request template generated an invalid Nginx configuration (`host not found in upstream "resolve"`), causing the proxy host to go offline.
**The Fix:** Bypassed the NPMplus UI template and injected a custom Nginx `auth_request` configuration directly into the Proxy Host's `advanced_config` via the API.

The custom Nginx configuration:
- Intercepts requests and checks `/oauth2/auth`.
- If unauthenticated, redirects to `/oauth2/sign_in`.
- Passes authenticated traffic through to the FastAPI backend (`127.0.0.1:8000`).

**Verification:**
- **Unauthenticated:** `curl -i https://<domain>/` returns a `302 Found` redirecting to the Microsoft login page.
- **Authenticated:** Completing the Microsoft login flow in the browser successfully grants access to the FastAPI Swagger UI.

---

### Day 3 Limitation: AppSec WAF False Positives & Availability

**The Issue:** After successfully implementing the Identity Gate, we attempted to re-enable CrowdSec AppSec (WAF) to inspect authenticated payloads (Defense in Depth). The WAF immediately triggered false-positive bans on legitimate browser traffic, causing a Denial-of-Service (DoS) lockout for the administrator.

**Troubleshooting & Root Cause Analysis:**
1. **Failure Action:** The default `APPSEC_FAILURE_ACTION=deny` caused the WAF to block all traffic when the AppSec connection glitched, rather than failing safely.
2. **Whitelist Bypass:** Standard CrowdSec allowlists (`cscli allowlists`) and parser whitelists (`s02-enrich`) **do not bypass AppSec bans**. AppSec operates on a separate inspection path before the LAPI decision engine.
3. **Bouncer Cache:** The NPMplus Lua bouncer caches AppSec bans locally in memory. Even after deleting decisions via `cscli decisions delete --all`, the bouncer continued to block the IP until the container was fully restarted.
4. **Mode Switch:** Attempting to switch the bouncer to `stream` mode (to maintain LAPI connectivity) did not resolve the false-positive lockouts.

**Resolution (Risk-Based Decision):**
To ensure the availability of the administrative interface and application, the CrowdSec bouncer was disabled in the NPMplus configuration file (`/data/crowdsec/crowdsec.conf`). While the Identity Gate (OAuth2-Proxy) provides strong authentication, the self-hosted WAF layer was deemed non-functional and a risk to uptime in this specific stack.

**Security Lesson (Architectural Limitation):**
This exercise highlights the complexity of self-hosted, tightly-coupled WAF integrations. While the WAF successfully blocked unauthenticated attacks on Day 2, layering it behind the identity gate introduced fragility. In a production environment, a managed service like Azure Front Door WAF or Azure Application Gateway would be required to provide reliable, high-availability inspection without risking the uptime of the reverse proxy.

## Day 4: Data Isolation (VNet Integration)

**Goal:** Migrate the PostgreSQL database off the public internet onto Azure VNet Integration, making it reachable only from inside the virtual network.

**The Gap:** The database was deployed with a public IP and a wide-open firewall rule (`0.0.0.0` - `255.255.255.255`). Bots continuously scan port 5432, and any data in transit risked interception.

**Implementation:**

### 1. Backup Before Migration
- Confirmed the database was publicly accessible by connecting directly from the local laptop.
- Executed a logical backup using `pg_dump` from the local laptop while the database was still public.
- Verified the backup file was non-empty and contained real schema/data.

### 2. Migrate to VNet Integration (Terraform)
- **`network.tf`**: Added a delegated subnet (`snet-db`, `10.0.2.0/24`) and a Private DNS Zone (`privatelink.postgres.database.azure.com`).
- **`postgresql.tf`**: Removed the `allow_all` firewall rule. Added `public_network_access_enabled = false`, `delegated_subnet_id`, and `private_dns_zone_id` to the PostgreSQL server.
- **`vm.tf`**: Removed the dependency on the deleted firewall rule from the VM's `depends_on` block to prevent the VM from being destroyed during the database replacement.
- Ran `terraform apply`. The database was destroyed and recreated inside the VNet. The VM was left untouched.

### 3. Restore and Verify Isolation
- **Proved isolation:** Attempted to connect from the local laptop. The connection failed with `No address associated with hostname`, proving the public DNS record was removed and the database is invisible to the internet.
- **Restore via jump host:** Copied the backup file to the VM via `scp`, then used the VM (which is inside the VNet) to run `psql` and restore the data.
- **Verified recovery:** Used the authenticated Swagger UI to call `GET /entries`. The app successfully returned the restored data, proving end-to-end connectivity between the VM and the private database.

**Security Lesson (Zero Trust Networking):**
Databases should never be exposed to the public internet, even with firewalls. By moving the database into a delegated VNet subnet and using a Private DNS Zone, we eliminated the public attack surface entirely. Only resources inside the VNet (like the application VM) can reach the database.

## Final Automation: Immutable Infrastructure

**Goal:** Ensure the entire zero-trust architecture (including TLS, WAF, and Zero Plaintext Secrets) can be destroyed and rebuilt from scratch with a single `terraform apply`.

**Implementation:**
- Updated `scripts/cloud-init.yaml` to automate the installation and configuration of Docker, NPMplus, CrowdSec, FastAPI, and OAuth2-Proxy.
- Added wrapper scripts (`start-learningsteps.sh` and `start-oauth2-proxy.sh`) to `cloud-init` that fetch secrets from Key Vault at boot and write ephemeral environment variables.
- Successfully executed a full `terraform destroy` and `terraform apply`.

**Verification:**
- Verified the new VM booted, `cloud-init` completed without errors, and both the App and OAuth2-Proxy services started automatically using secrets fetched from Key Vault.
- Used the NPMplus API to recreate the Proxy Host and TLS certificate, verifying the Identity Gate (Entra ID) and the App were fully operational.

**Conclusion:**
The LearningSteps environment is now a fully codified, immutable deployment. It enforces identity-based access, encrypted transit, a private database, and zero plaintext secrets on disk.

## Day 5 (Bonus): Advanced Hardening & Recommendations

**Goal:** Implement micro-segmentation and application-layer rate limiting, and document architectural recommendations for enterprise-scale defenses.

**Implementation:**

### 1. Network Micro-segmentation
- **The Gap:** While the database was isolated in a private VNet, there were no subnet-level firewalls preventing lateral movement from the application subnet to the database subnet.
- **The Fix:** Created a Network Security Group (`nsg-db`) and associated it with the database subnet (`snet-db`). The NSG enforces a default-deny rule for all inbound traffic, explicitly allowing only TCP port 5432 from the application subnet (`10.0.1.0/24`).

### 2. Application Rate Limiting
- **The Gap:** The FastAPI application was vulnerable to request flooding and automated scraping by authenticated users.
- **The Fix:** Injected an Nginx `limit_req_zone` directive into the NPMplus `advanced_config`. This limits clients to 10 requests per second, with a burst allowance of 20, protecting the application from Layer 7 Denial of Service (DoS) attacks.

### 3. Architectural Recommendations (Future State)
For a true production deployment, the following enterprise controls should be implemented:

- **Managed WAF (Azure Front Door):** While the self-hosted CrowdSec WAF proved effective in testing, the NPMplus Lua bouncer is fragile in a Dockerized environment. Replacing it with **Azure Front Door Premium** (or Application Gateway WAF_v2) would provide a fully managed, highly available WAF with built-in DDoS protection and OWASP CRS rules.
- **Azure Bastion (Remove Public IP):** To eliminate the VM's public SSH attack surface entirely, deploy Azure Bastion into a dedicated `/26` subnet (`AzureBastionSubnet`). This allows secure, browser-based RDP/SSH via the Azure Portal. To maintain public web access, a Load Balancer or NAT Gateway would be required.