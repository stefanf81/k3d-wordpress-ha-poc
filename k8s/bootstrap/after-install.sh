#!/bin/sh
set -eu

# Site-wide PoC defaults. Runs last on every reconcile, so these win over
# anything set earlier; add plugin-specific WP-CLI settings here. Seeded
# articles keep accepting comments because seed-site.sh opens them per post.
wp option update blog_public 0
wp option update default_comment_status closed
wp option update default_ping_status closed
