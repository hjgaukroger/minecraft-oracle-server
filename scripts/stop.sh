#!/bin/bash
screen -p 0 -S mc -X stuff "stop$(printf '\r')"
while pgrep -u ubuntu -f "paper.jar" > /dev/null; do sleep 1; done
