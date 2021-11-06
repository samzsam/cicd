FROM httpd:2.4
COPY ./public-html/ /usr/local/apache2/htdocs/
#COPY index.html /usr/local/apache2/htdocs/index.html
