#!/bin/bash
if [ ! "$(docker ps -q -f name=trello-scraper-app)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=trello-scraper-app)" ]; then
        # cleanup
        docker rm trello-scraper-app
    fi
    # run container
    docker run -d --name trello-scraper-app \
               -v $(pwd):/app \
               --env-file .env \
               trello-scraper tail -f /dev/null
fi
