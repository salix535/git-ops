#!/bin/bash
set -euo pipefail

sed -e 's/`pufnica_kb2020`/`bitnami_wordpress`/g' \
    -e 's/USE `bitnami_wordpress`;//g' \
    -e 's/CREATE DATABASE.*;//g' \
    -e 's/wp6m_/wp_/g' \
    ~/Downloads/169_254_0_2.sql > ~/Downloads/wordpress_fixed.sql

echo "Fixed dump written to ~/Downloads/wordpress_fixed.sql"
