.PHONY: ping deploy-staging deploy-production inventory-list

ping:
	ansible all -i inventories/staging/hosts.ini -m ping

deploy-staging:
	ansible-playbook -i inventories/staging/hosts.ini site.yml

deploy-production:
	ansible-playbook -i inventories/production/hosts.ini site.yml

inventory-list:
	ansible-inventory --list
