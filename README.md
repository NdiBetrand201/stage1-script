# DevOps Intern Stage 1 Task - Automated Deployment Script

## Overview
This repository contains a Bash script (`deploy.sh`) that automates the deployment of a FastAPI Dockerized application to an AWS EC2 instance. The script handles repository cloning, remote server setup (including SSH with .pem key from ~/.ssh), Docker deployment, Nginx configuration, and validation with comprehensive logging and error handling.

## Features
- Input validation for Git and SSH details.
- Clones or updates Git repository.
- Installs Docker, Docker Compose, and Nginx on EC2.
- Deploys FastAPI app in Docker container.
- Configures Nginx reverse proxy.
- Validates deployment, ensures idempotency, and provides cleanup.
- Logs to timestamped file.

## Prerequisites
- AWS EC2 Ubuntu 22.04 instance (Public IP: 13.247.178.255).
- GitHub repo with FastAPI app and Dockerfile.
- SSH key (`HNG13_stage1_betrand.pem`) stored in ~/.ssh with chmod 400 permissions.
- Local Bash, Git, SSH.

## Usage
1. Clone this repo: `git clone https://github.com/YOUR_USERNAME/devops-task.git`
2. `cd devops-task`
3. `./deploy.sh`
4. Enter details (use ~/.ssh for key path).
5. For cleanup: `./deploy.sh --cleanup`

## Input Parameters
- Git Repository URL: e.g., `https://github.com/YOUR_USERNAME/fastapi-sample-app.git`
- Personal Access Token: GitHub PAT.
- Branch Name: `main` (default).
- SSH Username: `ubuntu`.
- Server IP: `13.247.178.255`.
- SSH Key Path: `~/.ssh/HNG13_stage1_betrand.pem`
- Application Port: `8000`.


