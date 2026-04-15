.PHONY: ping deploy-staging deploy-production inventory-list ping-nfs deploy-nfs restart-nfs install-requirements ping-k3s install-k3s upgrade-k3s reboot-k3s

install-requirements:
	ansible-galaxy collection install -r requirements.yml

ping:
	ansible all -i inventories/staging/hosts.ini -m ping

deploy-staging:
	ansible-playbook -i inventories/staging/hosts.ini site.yml

deploy-production:
	ansible-playbook -i inventories/production/hosts.ini site.yml

inventory-list:
	ansible-inventory --list

ping-nfs:
	ansible nfs_servers -i inventories/k3s/inventory-nfs.yml -m ping

deploy-nfs:
	ansible-playbook -i inventories/k3s/inventory-nfs.yml playbooks/nfs-server.yml

restart-nfs:
	ansible nfs_servers -i inventories/k3s/inventory-nfs.yml -m ansible.builtin.systemd -a "name=nfs-kernel-server state=restarted" --become

ping-k3s:
	ansible k3s_cluster -i inventories/k3s/inventory.yml -m ping

install-k3s:
	ansible-playbook k3s.orchestration.site -i inventories/k3s/inventory.yml
	ansible-playbook k3s.orchestration.site -i inventories/k3s/inventory.yml --tags kubeconfig

upgrade-k3s:
	ansible-playbook k3s.orchestration.site -i inventories/k3s/inventory.yml --tags upgrade

reboot-k3s:
	ansible k3s_cluster -i inventories/k3s/inventory.yml -m ansible.builtin.reboot --become
