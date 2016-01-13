This repo contains auxiliary scripts & config
to get a dev environment working.

Setup the software using this guide:
https://echo.co/blog/os-x-1010-yosemite-local-development-environment-apache-php-and-mysql-homebrew

Then copy files ending in .copyto to their respective places.

For local SSL, we're generating self-signed certificates.

Using openssl, the req.conf is required so we can
specify SANs.

The ssl-shared.inc is a file that's included by
each entry in the httpd-vhosts.conf file

Use this command to generate a certificate (new private key):
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -config req.conf -keyout private.key -out self-signed.crt

For an existing private key:
openssl req -new -days 3650 -nodes -x509 -config req.conf -key private.key -out self-signed.crt
