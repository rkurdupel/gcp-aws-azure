# so it allows to use domain and access vm from website not from console by ip without it only from
#   console if only private_ip is present , manage traffic /health requests

# receives traffic from internet and distribute to app vms
resource "aws_lb" "this" {
    name = "${var.network_name}"
    internal = false    # public alb , accessible from internet
    load_balancer_type = "application"
    security_groups = [var.security_group_id]
    subnets = var.public_subnet_ids

    tags = {
        Name = "${var.network_name}-alb"
    }
}

# pool of app vms that receive traffic
resource "aws_lb_target_group" "this" {
    name = "${var.network_name}-tg"
    port = var.app_port
    protocol = "HTTP"
    vpc_id = var.vpc_id

 
#   1. You open website.
#   2. ALB sends request to app-1.
#   3. You click ETH.
#   4. ALB may send next request to app-2.
#   5. app-2 may not have the same session/cookie state yet.
#   6. Page looks like it did not update, so you press again.

#   With stickiness:

#   1. You open website.
#   2. ALB sends you to app-1.
#   3. ALB gives browser a cookie.
#   4. Your next clicks also go to app-1.
#   5. Coin/session state stays consistent.
    

    stickiness {
        type            = "lb_cookie"
        cookie_duration = 86400
        enabled         = true
    }

    health_check {
        path = var.health_check_path
        protocol = "HTTP"
        matcher = "200"
        interval = 30
        healthy_threshold = 2   # vm must pass health check 2 times in a row before alb sends traffic to it
        unhealthy_threshold = 3 # vm must fail health check three times in a row before alb stops sending traffic
        # if marked as a failure app-1 (unhealthy) sends traffic to app-2 (healthy)
        # check for success / pass every 30 sec automatically first during the boot of vm
        # if all vm are unhealthy - 503 service unavailable - app completely down (except auto scalling group is provided)
        timeout = 5
    }

    tags = {
        Name = "${var.network_name}-tg"
    }
}

# alb listens port 80 and forwards to target group (specific vm)
resource "aws_lb_listener" "http" {
    load_balancer_arn = aws_lb.this.arn
    port = 80
    protocol = "HTTP"

    default_action {
        type = "forward"
        target_group_arn = aws_lb_target_group.this.arn # arn - id
    }
}

