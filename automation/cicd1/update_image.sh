#!/bin/bash
sudo docker service update --image atsigncompany/secondary:dess_cicd \
 cicd1_secondary
sudo docker service update --image atsigncompany/secondary:dess_cicd \
 cicd3_secondary
sudo docker service update --image atsigncompany/secondary:prod \
 cicd5_secondary
