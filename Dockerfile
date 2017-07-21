FROM ubuntu:16.04

ENV DEBIAN_FRONTEND=noninteractive

# Install OVS
RUN apt-get update \ 
  && apt-get -y upgrade \
  && apt-get install -y openvswitch-switch=2.5.2-0ubuntu0.16.04.1 \
  && apt-get install -y ruby-full \
  && apt-get install -y libjson-c2 \
  && apt-get install -y build-essential

# Install gems
RUN gem install bundler
COPY Gemfile .
RUN bundle

# Upload exporter
COPY exporter.rb .

ENTRYPOINT ["ruby", "exporter.rb"]