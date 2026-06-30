import { StackContext } from "sst/constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as cloudfrontOrigins from "aws-cdk-lib/aws-cloudfront-origins";
import * as certificatemanager from "aws-cdk-lib/aws-certificatemanager";
import * as route53 from "aws-cdk-lib/aws-route53";
import * as route53Targets from "aws-cdk-lib/aws-route53-targets";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";
import { config } from "../config.js";
import { stagingSiteLabel } from "../lib/stagingSiteLabel.js";

export function DeployInfra({ stack, app }: StackContext) {
  const isStaging = app.stage === "staging";
  const subdomainName = isStaging
    ? stagingSiteLabel(config.subdomainName)
    : config.subdomainName;
  const domainName = `${subdomainName}.${config.domainBase}`;
  const bucketName = domainName;
  // Staging uses the same ACM ARN as prod (e.g. *.domain); no separate staging certificate.
  const certificateArn = config.certificateArn;
  const accountId = config.accountId;
  const useExistingBucket = config.useExistingBucket;
  const subdomainDeploy = config.subdomainDeploy;

  // Create unique construct ID prefix based on subdomain to avoid conflicts
  // Replace dots with hyphens so the prefix is safe for CDK construct IDs and CloudFormation names
  const constructIdPrefix = `${subdomainName.replace(/\./g, "-").charAt(0).toUpperCase() + subdomainName.replace(/\./g, "-").slice(1)}Website`;

  // Create or reference S3 bucket for static website hosting (also used for Serverless deployment artifacts via dev-deploy)
  let websiteBucket: s3.IBucket;
  
  if (useExistingBucket) {
    // Reference existing bucket
    websiteBucket = s3.Bucket.fromBucketName(stack as any as Construct, `${constructIdPrefix}Bucket`, bucketName);
  } else {
    // Create new S3 bucket for static website hosting
    websiteBucket = new s3.Bucket(stack as any as Construct, `${constructIdPrefix}Bucket`, {
      bucketName: bucketName,
      publicReadAccess: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ACLS,
      websiteIndexDocument: "index.html",
      websiteErrorDocument: "index.html",
      cors: [
        {
          allowedHeaders: [],
          allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.HEAD],
          allowedOrigins: ["*"],
          exposedHeaders: [],
        },
      ],
    });
  }

  // Create CloudFront distribution with S3 website endpoint
  const s3WebsiteEndpoint = `${bucketName}.s3-website.${stack.region}.amazonaws.com`;

  // When subdomainDeploy is true, attach custom domain + certificate to CloudFront
  // When false, CloudFront is created without a custom domain (accessible via *.cloudfront.net)
  const distributionProps: cloudfront.DistributionProps = {
    defaultBehavior: {
      origin: new cloudfrontOrigins.HttpOrigin(s3WebsiteEndpoint, {
        protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
      }),
      viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
    },
    comment: domainName,
    ...(subdomainDeploy && {
      domainNames: [domainName],
      certificate: certificatemanager.Certificate.fromCertificateArn(
        stack as any as Construct, `${constructIdPrefix}Certificate`, certificateArn
      ),
    }),
  };

  const distribution = new cloudfront.Distribution(
    stack as any as Construct, `${constructIdPrefix}Distribution`, distributionProps
  );

  // Only create Route53 subdomain record when subdomainDeploy is enabled
  if (subdomainDeploy) {
    const hostedZone = route53.HostedZone.fromLookup(stack as any as Construct, "HostedZone", {
      domainName: config.domainBase,
    });

    new route53.ARecord(stack as any as Construct, `${constructIdPrefix}ARecord`, {
      zone: hostedZone,
      recordName: domainName,
      target: route53.RecordTarget.fromAlias(
        new route53Targets.CloudFrontTarget(distribution)
      ),
    });
  }

  // Add bucket policy after CloudFront is created
  // This allows CloudFront to access the bucket
  // Note: Bucket policies can only be added when creating a new bucket
  // For existing buckets, ensure the bucket policies are configured manually
  if (!useExistingBucket && websiteBucket instanceof s3.Bucket) {
    websiteBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: "AllowCloudFrontServicePrincipal",
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal("cloudfront.amazonaws.com")],
        actions: ["s3:GetObject"],
        resources: [`${websiteBucket.bucketArn}/*`],
        conditions: {
          ArnLike: {
            "AWS:SourceArn": `arn:aws:cloudfront::${accountId}:distribution/${distribution.distributionId}`,
          },
        },
      })
    );

    // Also add public read access policy
    websiteBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:GetObject"],
        resources: [`${websiteBucket.bucketArn}/*`],
      })
    );
  }

  // Docker (ECR + Lambda) is optional: created only when the user runs scripts/docker/docker-deploy.sh.
  // No Docker resources in this stack by default.

  // Outputs
  const outputs: Record<string, string> = {
    BucketName: bucketName,
    CloudFrontDistributionId: distribution.distributionId,
    CloudFrontDomainName: distribution.distributionDomainName,
    WebsiteUrl: `https://${domainName}`,
  };

  // Add bucket website URL only if bucket was created (not referenced)
  if (!useExistingBucket && websiteBucket instanceof s3.Bucket) {
    outputs.BucketWebsiteUrl = websiteBucket.bucketWebsiteUrl;
  } else {
    outputs.BucketWebsiteUrl = `http://${bucketName}.s3-website.${stack.region}.amazonaws.com`;
  }

  stack.addOutputs(outputs);
}