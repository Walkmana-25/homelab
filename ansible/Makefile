.PHONY: ping deploy-staging deploy-production inventory-list ping-nfs deploy-nfs restart-nfs install-requirements ping-k3s install-k3s upgrade-k3s reboot-k3s deploy-argocd copy-kubeconfig check lint install-lint

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

install-k3s:
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags kubeconfig
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/fetch-kubeconfig.yml
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/argocd.yml

upgrade-k3s:
	ansible-playbook -vv k3s.orchestration.site -i inventories/k3s/inventory.yml --tags upgrade

reboot-k3s:
	ansible -vv k3s_cluster -i inventories/k3s/inventory.yml -m ansible.builtin.reboot --become

deploy-argocd:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/argocd.yml

copy-kubeconfig:
	ansible-playbook -vv -i inventories/k3s/inventory.yml playbooks/fetch-kubeconfig.yml
