#!/bin/sh
# Publishes auk-lang.org: site/ and install.sh to the web server's document root.
#
#   scripts/deploy_site.sh [<host>]        # default 108.181.4.231
#
# Copies the files to ~/auk-lang-setup/public_html on the host (as you), then installs them into
# /var/www/auk-lang.org/public_html with sudo (asks for your password there). Cloudflare sits in
# front, so a changed page can take a few minutes to show (or purge its cache).
set -eu
host=${1:-108.181.4.231}
root=$(cd "$(dirname "$0")/.." && pwd)
stage=auk-lang-setup/public_html
docroot=/var/www/auk-lang.org/public_html

ssh "$host" "mkdir -p ~/$stage"
scp -q "$root"/site/* "$root/install.sh" "$host:$stage/"
ssh -t "$host" "sudo install -m 644 -o root -g root ~/$stage/* $docroot/ && ls -la $docroot"
