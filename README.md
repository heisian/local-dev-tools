We're generating self-signed certificates for 
local dev.

Using openssl, the req.conf is required so we can
specify SANs.

The ssl-shared.inc is a file that's included by
each entry in the httpd-vhosts.conf file

Use this command to generate a certificate:
openssl req -new -days 3650 -nodes -x509 -config "/Volumes/HDD/Revolve/WEB DEV/ssl/req.conf" -key "/Volumes/HDD/Revolve/WEB DEV/ssl/private.key" -out "/Volumes/HDD/Revolve/WEB DEV/ssl/self-signed.crt"
