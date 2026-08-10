# Use the official Node.js image (Alpine variant keeps the image small)
FROM node:22-alpine

# Set the working directory inside the container
WORKDIR /app

# Copy package.json first so dependencies can be cached across builds
COPY package.json ./

# Install dependencies
RUN npm install

# Copy the rest of the backend source code
COPY . .

# The Express server listens on port 5000
EXPOSE 5000

# Start the server
CMD ["npm", "start"]
