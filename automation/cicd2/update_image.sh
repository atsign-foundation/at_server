#!/bin/bash
sudo docker service update --image atsigncompany/secondary:dess_cicd \
 cicd2_secondary
sudo docker service update --image atsigncompany/secondary:prod \
 cicd4_secondary
sudo docker service update --image atsigncompany/secondary:dess_cicd \
 cicd6_secondary
