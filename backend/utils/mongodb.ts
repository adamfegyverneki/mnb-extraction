import { MongoClient, Db } from 'mongodb';
import { logger } from './logger';

let cachedClient: MongoClient | null = null;
let cachedDb: Db | null = null;

/**
 * Connect to MongoDB
 * Uses connection pooling for serverless Lambda functions
 */
export async function connectToDatabase(): Promise<Db> {
  if (cachedClient && cachedDb) {
    logger.debug('Using cached MongoDB connection');
    return cachedDb;
  }

  const uri = process.env.MONGODB_URI;
  if (!uri) {
    throw new Error('MONGODB_URI environment variable is not set');
  }

  try {
    logger.debug('Creating new MongoDB connection');
    const client = new MongoClient(uri, {
      maxPoolSize: 10,
      minPoolSize: 1,
      serverSelectionTimeoutMS: 5000,
      socketTimeoutMS: 45000,
    });

    await client.connect();
    cachedClient = client;
    
    // Extract database name from URI or use default
    // If MONGODB_DB_NAME is set, use it; otherwise try to extract from URI pathname, or default to 'app'
    let dbName = process.env.MONGODB_DB_NAME;
    if (!dbName) {
      try {
        const url = new URL(uri);
        dbName = url.pathname.slice(1); // Remove leading slash
      } catch {
        // URL parsing failed, use default
      }
      dbName = dbName || 'app';
    }
    
    cachedDb = client.db(dbName);
    logger.info(`Successfully connected to MongoDB database: ${dbName}`);
    return cachedDb;
  } catch (error) {
    logger.error('Failed to connect to MongoDB:', error);
    throw error;
  }
}

/**
 * Close MongoDB connection
 * Useful for cleanup or testing
 */
export async function closeDatabase(): Promise<void> {
  if (cachedClient) {
    await cachedClient.close();
    cachedClient = null;
    cachedDb = null;
    logger.info('MongoDB connection closed');
  }
}

/**
 * Get database instance (must be connected first)
 */
export function getDatabase(): Db {
  if (!cachedDb) {
    throw new Error('Database not connected. Call connectToDatabase() first.');
  }
  return cachedDb;
}
