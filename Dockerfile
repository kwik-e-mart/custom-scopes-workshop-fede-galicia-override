FROM node:lts-alpine

RUN apk add bash curl envsubst

RUN curl https://cli.nullplatform.com/agent/install.sh | bash


WORKDIR /usr/src/app

COPY package*.json ./

RUN npm ci --only=production

RUN mkdir /mcp

ADD ./mcp.json /mcp/mcp.json 

ADD ./entrypoint.sh /mcp/entrypoint.sh

COPY . .

ENTRYPOINT /mcp/entrypoint.sh
