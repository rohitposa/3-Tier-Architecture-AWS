# ---------- Web ALB (internet-facing) ----------
resource "aws_lb" "web" {
  name               = "${var.project_name}-web-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.web_alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ---------- App ALB (internal) ----------
resource "aws_lb" "app" {
  name               = "${var.project_name}-app-alb"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.app_alb.id]
  subnets            = aws_subnet.app[*].id
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path    = "/health.php"
    matcher = "200"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
