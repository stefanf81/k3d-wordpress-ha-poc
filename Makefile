# Scripts run through bash so targets keep working even if a checkout loses
# the executable bit (e.g. after a GitHub web upload).

.PHONY: up down reset migrate-db reconfigure verify versions arch plugins \
	inventory test-ha test-ingress-ha check lint

up:
	bash ./start.sh

down:
	bash ./stop.sh

reset:
	bash ./reset.sh

migrate-db:
	bash ./migrate-mariadb-to-named-volume.sh

reconfigure:
	bash ./reconfigure.sh

verify:
	bash ./verify.sh

versions:
	bash ./versions.sh

arch:
	bash ./verify-arm64.sh

plugins:
	bash ./show-plugins.sh

inventory:
	bash ./wordpress-inventory.sh

test-ha:
	bash ./test-ha.sh

test-ingress-ha:
	bash ./test-ingress-ha.sh

# Runtime checks against a running lab: bootstrap idempotency, WP-Cron and
# clean inventory output.
check:
	bash ./check.sh

# Static checks; no cluster needed.
lint:
	bash ./lint.sh
