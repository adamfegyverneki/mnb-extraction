#!/usr/bin/env node
/**
 * Upload HTML/JS/CSS files to S3 and invalidate CloudFront cache
 * Usage: npm run upload
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { config } from "../config.js";

const subdomainName = config.subdomainName;
const bucketName = `${subdomainName}.${config.domainBase}`;
const distFolder = path.join(process.cwd(), "dist");

// Get CloudFront distribution ID from SST outputs
// This will be set after deployment
const getCloudFrontDistributionId = (): string => {
  // Read from SST outputs file
  const sstOutputsPath = path.join(process.cwd(), ".sst", "outputs.json");
  if (fs.existsSync(sstOutputsPath)) {
    try {
      const outputs = JSON.parse(fs.readFileSync(sstOutputsPath, "utf-8"));
      // Try to find CloudFrontDistributionId in outputs (check both old and new stack names)
      const distIdFromOutputs = outputs?.DeployInfra?.CloudFrontDistributionId 
        || outputs?.DeployInfraStack?.CloudFrontDistributionId
        || outputs?.WebsiteStack?.CloudFrontDistributionId;
      if (distIdFromOutputs) {
        return distIdFromOutputs;
      }
      // Fallback: search all stacks for CloudFrontDistributionId
      for (const stackName in outputs) {
        if (outputs[stackName]?.CloudFrontDistributionId) {
          return outputs[stackName].CloudFrontDistributionId;
        }
      }
    } catch (error) {
      console.error("Could not read SST outputs file:", error);
      process.exit(1);
    }
  }

  console.error(
    "Error: CloudFront Distribution ID not found.\n" +
    "Please run 'npm run deploy' first to create the infrastructure."
  );
  process.exit(1);
};

const uploadFiles = () => {
  if (!fs.existsSync(distFolder)) {
    console.error(`Error: dist folder not found at ${distFolder}`);
    process.exit(1);
  }

  const filesToUpload = ["index.html", "i.js", "i.css"];

  console.log(`Uploading files to s3://${bucketName}...`);

  filesToUpload.forEach((file) => {
    const localPath = path.join(distFolder, file);
    if (!fs.existsSync(localPath)) {
      console.warn(`Warning: ${file} not found, skipping...`);
      return;
    }

    const s3Path = `s3://${bucketName}/${file}`;
    console.log(`Uploading ${file}...`);
    try {
      execSync(`aws s3 cp "${localPath}" ${s3Path}`, { stdio: "inherit" });
    } catch (error) {
      console.error(`Failed to upload ${file}:`, error);
      process.exit(1);
    }
  });
};

const invalidateCloudFront = (distributionId: string) => {
  console.log(`Creating CloudFront invalidation for distribution ${distributionId}...`);
  const paths = ["/index.html", "/i.js", "/i.css"];

  try {
    execSync(
      `aws cloudfront create-invalidation --distribution-id ${distributionId} --paths ${paths.join(" ")}`,
      { stdio: "inherit" }
    );
  } catch (error) {
    console.error("Failed to create CloudFront invalidation:", error);
    process.exit(1);
  }
};

const main = () => {
  const distributionId = getCloudFrontDistributionId();
  uploadFiles();
  invalidateCloudFront(distributionId);
  console.log("Files uploaded and invalidation created.");
};

main();

