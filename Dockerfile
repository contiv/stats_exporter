FROM ubuntu:16.04

ENV DEBIAN_FRONTEND=noninteractive

# Install OVS
RUN apt-get update \ 
  && apt-get -y upgrade \
  && apt-get install -y openvswitch-switch=2.5.2-0ubuntu0.16.04.1 \
  ruby-full \
  libjson-c2 \
  build-essential

# Install gems
COPY Gemfile .
RUN gem install bundler
RUN bundle

# Upload exporter
COPY exporter.rb .

ENTRYPOINT ["ruby", "exporter.rb"]