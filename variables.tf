variable "private_key_path" {
    default = "files/jtform.pem"
    description = "The path to the AWS key pair to use for resources."
}
 
 variable "ami_key_pair_name" {
     default = "jtform"
 }

 variable "install_httpd" {
    description = "location of bash script."
    default = "files/installhttpd.sh"
 }