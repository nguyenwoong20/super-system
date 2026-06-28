import { writeFileSync } from "node:fs";
import { Diagram } from "file:///C:/Users/LENOVO/.gemini/antigravity/brain/b73c1137-91e3-49c9-ac56-62012ea07264/scratch/drawio-ai-kit/src/builder.mjs";
import { group, frame, icon, endpoint, renderTree } from "file:///C:/Users/LENOVO/.gemini/antigravity/brain/b73c1137-91e3-49c9-ac56-62012ea07264/scratch/drawio-ai-kit/src/layout-engine.mjs";

const d = new Diagram("super-system-arch");

const users = endpoint("users", "Users (Internet)");

// ALB in Public Subnet
const albIcon = icon("alb", "application_load_balancer", "Application Load Balancer");
const publicSubnet = group("pub_subnet", "group_subnet", "Public Subnets (Multi-AZ)", { dir: "col", pad: 20 }, [albIcon]);

// ECS Services in Private Subnet
const ecsNginx = icon("nginx", "nginx", "Nginx Gateway (ECS)");
const ecsAuth = icon("auth", "ecs_task", "Auth Service (ECS)");
const ecsTicket = icon("ticket", "ecs_task", "Ticket Service (ECS)");

const ecsFrame = frame("ecs_services", "", { dir: "row", gap: 20, fill: "none", stroke: "none" }, [
  ecsNginx,
  ecsAuth,
  ecsTicket
]);
const ecsGroup = group("ecs_cluster", "group_ecs_cluster", "ECS Cluster (Fargate)", { dir: "col", pad: 20 }, [ecsFrame]);

// EFS / RDS in Private Subnet
const dbAuth = icon("db_auth", "postgres", "Auth DB (Postgres)");
const dbTicket = icon("db_ticket", "postgres", "Ticket DB (Postgres)");
const kafka = icon("kafka", "kafka", "Kafka (Events)");

const dbFrame = frame("dbs", "", { dir: "row", gap: 20, fill: "none", stroke: "none" }, [
  dbAuth,
  dbTicket,
  kafka
]);

const efsGroup = group("efs", "group_efs_file_system", "EFS (Shared Storage)", { dir: "col", pad: 20 }, [dbFrame]);

const privateSubnet = group("priv_subnet", "group_subnet", "Private Subnets (Multi-AZ)", { dir: "col", gap: 30, pad: 20 }, [ecsGroup, efsGroup]);

// VPC
const vpc = group("vpc", "group_vpc", "VPC (10.0.0.0/16)", { dir: "col", gap: 30, pad: 30 }, [publicSubnet, privateSubnet]);

// Region
const region = group("region", "group_region", "AWS Region (ap-southeast-1)", { dir: "col", pad: 30 }, [vpc]);

// Cloud
const aws = group("aws", "group_aws_cloud_alt", "AWS Cloud", { dir: "col", pad: 30 }, [region]);

const root = frame("root", "", { dir: "row", gap: 60, align: "center", fill: "none", stroke: "none" }, [users, aws]);

renderTree(d, root);

// Edges
d.link("users", "alb", "HTTPS");
d.link("alb", "nginx", "HTTP 80");
d.link("nginx", "auth", "/api/auth");
d.link("nginx", "ticket", "/api/tickets");
d.link("auth", "db_auth", "TCP 5432");
d.link("ticket", "db_ticket", "TCP 5432");
d.link("auth", "kafka", "Publish Events");
d.link("ticket", "kafka", "Consume Events");

const xml = `<mxfile host="app.diagrams.net"><diagram name="Architecture" id="arch">${d.toXML()}</diagram></mxfile>`;
writeFileSync("./architecture.drawio", xml);
console.log("Wrote architecture.drawio");
