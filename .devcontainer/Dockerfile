# Use the official Microsoft Ubuntu dev container image
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-venv \
    ansible \
    ansible-lint \
    sshpass \
    git \
    make \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js (via NodeSource) for Gemini CLI
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI globally
RUN npm install -g @google/gemini-cli

# Set up a working directory (this will be overridden by the workspace mount)
WORKDIR /workspaces/homelab

# Set up an alias for python to python3
RUN ln -s /usr/bin/python3 /usr/bin/python

# Pre-install some common Python tools if needed
# Note: Project-specific dependencies will be installed via postCreateCommand
