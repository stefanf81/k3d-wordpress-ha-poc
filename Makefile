.PHONY: check-bootstrap up down reset migrate-db reconfigure test-ha test-ingress-ha verify versions plugins inventory

up:
	./start.sh

down:
	./stop.sh

reset:
	./reset.sh

migrate-db:
	./migrate-mariadb-to-named-volume.sh

reconfigure:
	./reconfigure.sh

test-ha:
	./test-ha.sh

test-ingress-ha:
	./test-ingress-ha.sh

verify:
	./verify.sh

versions:
	./versions.sh

plugins:
	./show-plugins.sh

inventory:
	./wordpress-inventory.sh

check-bootstrap:
	./check-bootstrap-idempotency.sh

check-wp-cron:
	./check-wp-cron.sh

check-plugin-idempotency:
	./check-plugin-idempotency.sh

check-inventory-clean:
	./check-inventory-clean.sh
