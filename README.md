# Odoo 17 Docker Installer

This repository contains a **one-shot** installer script for running **Odoo 17** with **PostgreSQL** in Docker containers, behind **Nginx** with **Let's Encrypt SSL**.

## Features
- Installs Docker and Compose plugin (if missing)
- Deploys Odoo 17 and PostgreSQL containers
- Configures persistent volumes for Odoo data and Postgres data
- Mounts `odoo.conf` with your **master password**
- Sets up Nginx reverse proxy
- Automatically obtains and configures Let's Encrypt SSL certificate

## Quick Install

Run this on a fresh Ubuntu 20.04/22.04/24.04 server:

```bash
sudo bash -c "apt-get update -y && apt-get install -y curl && curl -fsSL https://raw.githubusercontent.com/kobzpanel/install-odoo17/refs/heads/main/install-odoo17-docker.sh | bash"
