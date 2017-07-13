FROM ruby:2.4.1-slim

# Install gems
RUN gem install bundler
COPY Gemfile .
RUN bundle

# Upload exporter
COPY exporter.rb .

ENTRYPOINT ["ruby", "exporter.rb"]

