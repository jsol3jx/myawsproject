#!/bin/bash
sudo su
sudo yum -y install httpd
echo "Hello World" >> /var/www/html/index.html
sudo systemctl disable firewalld
sudo systemctl enable httpd
sudo systemctl start httpd