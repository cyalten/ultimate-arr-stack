#!/bin/sh
# Your VPN leak check here
# Exit 0 = pass, non-zero = fail
curl -fsS -m 10 https://ifconfig.co/ip | grep -q "your-expected-ip"
