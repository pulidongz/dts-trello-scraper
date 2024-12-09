# Setup

Generate a `TRELLO_API_KEY` from https://trello.com/app-key
<br>
and `TRELLO_API_TOKEN` from the 'Token' link in 'API key' tab.

Add `OPENAI_API_KEY` to `.env` file.

Then run:
```bash
docker build -t trello-scraper .
```

# Start Container
```bash
./bin/start.sh
```

# Install the gems
```bash
docker exec -it trello-scraper-app bundle install
```

# Run scraper
```bash
docker exec -it trello-scraper-app ruby trello_scraper.rb
```