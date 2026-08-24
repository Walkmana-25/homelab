.PHONY: ping deploy-staging deploy-production inventory-list ping-nfs deploy-nfs restart-nfs install-requirements ping-k3s install-k3s upgrade-k3s reboot-k3s deploy-argocd copy-kubeconfig check lint install-lint deploy-longhorn deploy-nfs-client ping-router deploy-router ping-node-exporter deploy-node-exporter restart-node-exporter ping-fluent-bit deploy-fluent-bit restart-fluent-bit deploy-loki-proxy configure-registry ping-linstor deploy-linstor update-linstor restart-linstor ping-piraeus-prereq deploy-piraeus-prereq common

install-lint:
	pip install --break-system-packages -r requirements.txt

lint:
	ansible-lint -vv .

check: lint
	@echo "Checking syntax for all playbooks..."
	ansible-playbook -vv --syntax-check site.yml
	ansible-playbook -vv --syntax-check playbooks/*.yml
	@echo "Checking inventory files..."
	ansible-inventory -vv -i inventories/staging/hosts.ini --list > /dev/null
	ansible-inventory -vv -i inventories/production/hosts.ini --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-nfs.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-router.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-node-exporter.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-fluent-bit.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-linstor.yml --list > /dev/null
	ansible-inventory -vv -i inventories/k3s/inventory-piraeus.yml --list > /dev/null
	@echo "All checks passed!"

install-requirements:
	ansible-galaxy -vv collection install -r requirements.yml

ping:
	ansible -vv all -i inventories/staging/hosts.ini -m ping

deploy-staging:
	ansible-playbook -vv -i inventories/staging/hosts.ini site.yml

deploy-production:
	ansible-playbook -vv -i inventories/production/hosts.ini site.yml

inventory-list:
	ansible-inventory -vv --list

ping-nfs:
	ansible -vv nfs_servers -i inventories/k3s/inventory-nfs.yml -m ping

deploy-nfs:
	ansible-playbook -vv -i inventories/k3s/inventory-nfs.yml playbooks/nfs-server.yml

restart-nfs:
	ansible -vv nfs_servers -i inventories/k3s/inventory-nfs.yml -m ansible.builtin.systemd -a "name=nfs-kernel-server state=restarted" --become

ping-k3s:
	ansible -vv k3s_cluster -i inventories/k3s/inventory.yml -m ping

common:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/common.yml

install-k3s:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/common.yml
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/nfs-client.yml
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/btrfs-longhorn.yml
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags kubeconfig
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/fetch-kubeconfig.yml
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/argocd.yml

upgrade-k3s:
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags upgrade

reboot-k3s:
	ansible -vv k3s_cluster -i inventories/k3s/inventory.yml -m ansible.builtin.reboot --become

deploy-longhorn:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/btrfs-longhorn.yml

deploy-nfs-client:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/nfs-client.yml

deploy-argocd:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/argocd.yml

configure-registry:
	ansible-playbook -vv -i inventories/k3s/inventory.yml configure-registry.yml

copy-kubeconfig:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/fetch-kubeconfig.yml

ping-router:
	ansible -vv k3s_router -i inventories/k3s/inventory-router.yml -m ping

deploy-router:
	ansible-playbook -vv -i inventories/k3s/inventory-router.yml playbooks/router.yml

ping-node-exporter:
	ansible -vv nfs_servers:k3s_router:linstor_nodes -i inventories/k3s/inventory-node-exporter.yml -m ping

deploy-node-exporter:
	ansible-playbook -vv -i inventories/k3s/inventory-node-exporter.yml playbooks/node-exporter.yml

restart-node-exporter:
	ansible -vv nfs_servers:k3s_router:linstor_nodes -i inventories/k3s/inventory-node-exporter.yml -m ansible.builtin.systemd -a "name=node_exporter state=restarted" --become

ping-fluent-bit:
	ansible -vv nfs_servers:k3s_router:linstor_nodes -i inventories/k3s/inventory-fluent-bit.yml -m ping

deploy-fluent-bit:
	ansible-playbook -vv -i inventories/k3s/inventory-fluent-bit.yml playbooks/fluent-bit.yml

restart-fluent-bit:
	ansible -vv nfs_servers:k3s_router:linstor_nodes -i inventories/k3s/inventory-fluent-bit.yml -m ansible.builtin.systemd -a "name=fluent-bit state=restarted" --become

deploy-loki-proxy:
	ansible-playbook -vv -i inventories/k3s/inventory-router.yml playbooks/loki-proxy.yml

ping-linstor:
	ansible -vv linstor_nodes -i inventories/k3s/inventory-linstor.yml -m ping

deploy-linstor:
	ansible-playbook -vv -i inventories/k3s/inventory-linstor.yml playbooks/linstor.yml

update-linstor:
	ansible-playbook -vv -i inventories/k3s/inventory-linstor.yml playbooks/linstor.yml --tags update

restart-linstor:
	ansible -vv linstor_nodes -i inventories/k3s/inventory-linstor.yml -m ansible.builtin.systemd -a "name=linstor-satellite state=restarted" --become

ping-piraeus-prereq:
	ansible -vv piraeus_nodes -i inventories/k3s/inventory-piraeus.yml -m ping

deploy-piraeus-prereq:
	ansible-playbook -vv -i inventories/k3s/inventory-piraeus.yml playbooks/piraeus-prereq.yml
