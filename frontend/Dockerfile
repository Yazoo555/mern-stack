# Use the official Node.js image (Alpine variant keeps the image small)
FROM node:22-alpine

# Set the working directory inside the container
WORKDIR /app

# Copy package.json first so dependencies can be cached across builds
COPY package.json ./

# Install dependencies
RUN npm install

# Copy the rest of the frontend source code
COPY . .

# The Vite dev server listens on port 5173
EXPOSE 5173

# Run the Vite dev server bound to all interfaces so it is reachable
# from outside the container (Docker port mapping)
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
