# Optimizations
In our latest nginx-wordpress.conf (revolverobotics.com)
we're caching dynamic pages from Apache and serving
static content via NGINX only.  This way Apache only
needs to handle fresh dynamic content.

Additionally we were not previously (before 2016-01-31)
running Apache with the FastCGI/PHP-FPM handler.

The PHP-FPM works with apache via the mod_proxy_fcgi
module, which is only available in Apache 2.4+
This makes things easy b/c all we need to do is
`sudo yum install php70w-fpm` and add this line
to our `<VirtualHost>` directive:

`ProxyPassMatch ^/(.*\.php(/.*)?)$ fcgi://127.0.0.1:9000/var/www/[web_root]`

See `nginx-wordpress.conf` for the Wordpress-specific caching settings.
