SSLEngine On
SSLCipherSuite EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH
SSLProtocol All -SSLv2 -SSLv3
SSLHonorCipherOrder On
Header always set Strict-Transport-Security "max-age=63072000; includeSubdomains; preloa$
Header always set X-Frame-Options DENY
Header always set X-Content-Type-Options nosniff
# Requires Apache >= 2.4
SSLCompression off
SSLSessionTickets Off
SSLUseStapling on
SSLCertificateFile "/Volumes/HDD/Revolve/WEB DEV/ssl/self-signed.crt"
SSLCertificateKeyFile "/Volumes/HDD/Revolve/WEB DEV/ssl/private.key"

