# Use the official Microsoft Ubuntu dev container image
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-venv \
    sshpass \
    git \
    make \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set up a working directory (this will be overridden by the workspace mount)
WORKDIR /workspace

# Set up an alias for python to python3
RUN ln -s /usr/bin/python3 /usr/bin/python

# Pre-install some common Python tools if needed
# Note: Project-specific dependencies will be installed via postCreateCommand
