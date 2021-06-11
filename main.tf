terraform {
    required_version = ">= 0.14.9"
}

#Sets the provider to aws for terraform.
provider "aws" {
      region = "us-west-2" 
}

#creates a new vpc in my aws account with a block of ips in both ipv4 and 6.
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames                  = true
  enable_dns_support                    = true
  assign_generated_ipv6_cidr_block      = true
    
}

#Internet gatway that allows resources to hit the internet.
resource "aws_internet_gateway" "my_vpc_igw" {
  vpc_id = "${aws_vpc.my_vpc.id}"
  tags = {
    "Name" = "my_vpc_igw"
  }
}

#Route table with the new ip blocks associated to it.
resource "aws_route_table" "my_vpc_public_rt" {
  vpc_id = "${aws_vpc.my_vpc.id}"
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_vpc_igw.id
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id = aws_internet_gateway.my_vpc_igw.id
    }
}

#AWS Application Load Balancers require a subnet in two different availability zones for redunancy. This is subnet 1.
resource "aws_subnet" "my_vpc_public_uswest2a_sn" {
    vpc_id     = aws_vpc.my_vpc.id
    cidr_block = "10.0.0.0/24"
    availability_zone = "us-west-2a"
    ipv6_cidr_block = "${cidrsubnet(aws_vpc.my_vpc.ipv6_cidr_block, 8, 1)}"
    tags = {
    Name = "my_vpc_public_uswest2a_sn"
  }
}

#Associating the subnet 1 to route table.
resource "aws_route_table_association" "my_vpc_public_rt_assoc_uswest2a_sn" {
  subnet_id      =  aws_subnet.my_vpc_public_uswest2a_sn.id
  route_table_id = "${aws_route_table.my_vpc_public_rt.id}"
  
}

#AWS Application Load Balancers require a subnet in two different availability zones for redunancy. This is subnet 2.
resource "aws_subnet" "my_vpc_public_uswest2b_sn" {
    vpc_id     = aws_vpc.my_vpc.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "us-west-2b"
    ipv6_cidr_block = "${cidrsubnet(aws_vpc.my_vpc.ipv6_cidr_block, 8, 200)}"
    tags = {
    Name = "my_vpc_public_uswest2b_sn"
  }
}

#Associating the subnet 2 to route table.
resource "aws_route_table_association" "my_vpc_public_rt_assoc_uswest2b_sn" {
  subnet_id      =  aws_subnet.my_vpc_public_uswest2b_sn.id
  route_table_id = "${aws_route_table.my_vpc_public_rt.id}"
}

#Creating an s3 bucket for log collection for troubleshooting, if needed. 
resource "aws_s3_bucket" "my_vpc_s3bucket" {
   bucket = "my-vpc-s3bucket"
   acl = "private"
   versioning {
      enabled = true
   }
   tags = {
     Name = "alb-bucket1"
    }
}

#Application Load Balancer creation with the s3 bucket attached. 
resource "aws_alb" "my_vpc_alb" {
  name               = "my-vpc-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.my_vpc_alb_sg.id]
  ip_address_type = "dualstack"
  subnets = [
      "${aws_subnet.my_vpc_public_uswest2a_sn.id}",
      "${aws_subnet.my_vpc_public_uswest2b_sn.id}"
      ]
      access_logs {
        bucket = aws_s3_bucket.my_vpc_s3bucket.bucket
        prefix = "ALB-Logs"
        }   
}

#Security group for the application load balancer that allows internet access via port 80 & 8080 only. Allows all traffic out. 
#configured for both ipv4 and 6.
resource "aws_security_group" "my_vpc_alb_sg" {
  name = "my_vpc_alb_sg"
  vpc_id = aws_vpc.my_vpc.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
        from_port = 8080
        to_port = 8080
        protocol = "TCP"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        ipv6_cidr_blocks = ["::/0"]
    }
    egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      ipv6_cidr_blocks = ["::/0"]
    }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    "Name" = "my_vpc_alb_sg"
  }
}
# forward rule that will only accept incoming HTTP requests on port 80 and forwards to port target:8080.
resource "aws_alb_listener" "my_alb_listener" {  
    load_balancer_arn = aws_alb.my_vpc_alb.arn
    port = 80  
    protocol = "HTTP"
    default_action {    
        type = "forward"
        target_group_arn = aws_alb_target_group.my_vpc_alb_target_group.arn
    }
}
# ALB forwards requests to the target group with the web server ec2 vms.
resource "aws_alb_target_group" "my_vpc_alb_target_group" {
    name = "my-vpc-alb-target-group"
    port = 80
    protocol = "HTTP"
    target_type = "instance"
    vpc_id = aws_vpc.my_vpc.id
    tags = {
        name = "my-vpc-alb-target-group"
    }
    health_check {
      healthy_threshold   = 3    
        unhealthy_threshold = 10    
        timeout             = 5    
        interval            = 10    
        path                = "/"
        port                = 80
    }
    
    lifecycle {
        create_before_destroy = true
    }
}

#Autoscaling Attachment
resource "aws_autoscaling_attachment" "my_vpc_autoscale_attachment" {    
    alb_target_group_arn   = "${aws_alb_target_group.my_vpc_alb_target_group.arn}"
    autoscaling_group_name = "${aws_autoscaling_group.my_vpc_autoscaling_group.id}"
}

# setup launch configuration for the auto-scaling.
resource "aws_launch_configuration" "my_vpc_launch_configuration" {

   #The EC2 image is centos7, I've added my own ssh keypair to them as well as a public IP for troubleshooting purposes. 
    image_id = "ami-0686851c4e7b1a8e1"
    instance_type = "t2.micro"
    key_name = var.ami_key_pair_name #SSH key name
    security_groups = [aws_security_group.my_vpc_launch_config_sg.id]
    associate_public_ip_address = true
    
    lifecycle {
        create_before_destroy = true
    }
    #installs simple httpd webserver on each instance.
    user_data = file(var.install_httpd)
}


# security group for for launch config my_vpc_launch_configuration that attaches to instances.
resource "aws_security_group" "my_vpc_launch_config_sg" {
    vpc_id = aws_vpc.my_vpc.id
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 8080
        to_port = 8080
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
      "Name" = "my_vpc_launch_config_sg"
    }
}

# creates an autoscaling attachmet to my_vpc_alb_target_group.
#resource "aws_autoscaling_attachment" "my_vpc_aws_autoscaling_attachment" {
#    alb_target_group_arn = aws_alb_target_group.my_vpc_alb_target_group.arn
#    autoscaling_group_name = aws_autoscaling_group.my_vpc_autoscaling_group.id
#}

# Creates the autoscaling group.
resource "aws_autoscaling_group" "my_vpc_autoscaling_group" {
    name = "my_vpc_autoscaling_group"
    desired_capacity = 2 # ideal number of instance alive
    min_size = 2 # min number of instance alive
    max_size = 5 # max number of instance alive
    health_check_type = "ELB"

    # allows deleting the autoscaling group without waiting for all instances in the pool to terminate
    force_delete = true

    launch_configuration = aws_launch_configuration.my_vpc_launch_configuration.id
    vpc_zone_identifier = [
        aws_subnet.my_vpc_public_uswest2a_sn.id,
        aws_subnet.my_vpc_public_uswest2b_sn.id 
    ]
    timeouts {
        delete = "15m" # timeout duration for instances
    }
    lifecycle {
        # ensure the new instance is only created before the other one is destroyed.
        create_before_destroy = true
    }
}

#creates an aws wafv2 acl rule that blocks access from Hong Kong. 
resource "aws_wafv2_web_acl" "my_vpc_waf_hk_acl" {
  name     = "my-vpc-waf-hk-acl"
  scope    = "REGIONAL"
  #capacity = 1

  default_action {
    allow {}
  }

  rule {
    name     = "Block_HK"
    priority = 1

    action {
      block {}
    }

    statement {

      geo_match_statement {
        country_codes = ["HK"]
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "geomatch"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "my-vpc-waf-hk-acl"
    sampled_requests_enabled   = false
  }
}

# Associates this acl to the application load balancer.
resource "aws_wafv2_web_acl_association" "my_vpc_web_acl_association_my_alb" {
  resource_arn = aws_alb.my_vpc_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.my_vpc_waf_hk_acl.arn
}

#outputs the Application load balaner url.
output "alb-url" {
    value = aws_alb.my_vpc_alb.dns_name
}
