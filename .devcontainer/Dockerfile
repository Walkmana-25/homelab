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

# Install yamllint for YAML linting
RUN pip3 install --break-system-packages yamllint

# Install kustomize
RUN KUSTOMIZE_VERSION=5.6.0 && \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin && \
    chmod +x /usr/local/bin/kustomize

# Install kubeconform for Kubernetes manifest validation
RUN KUBECONFORM_VERSION=0.6.7 && \
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin kubeconform && \
    chmod +x /usr/local/bin/kubeconform

# Install kompose for converting Docker Compose to Kubernetes manifests
RUN KOMPOSE_VERSION=v1.38.0 && \
    curl -fsSL "https://github.com/kubernetes/kompose/releases/download/${KOMPOSE_VERSION}/kompose-linux-amd64" \
    -o /usr/local/bin/kompose && \
    chmod +x /usr/local/bin/kompose

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
