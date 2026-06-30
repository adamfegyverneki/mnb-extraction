export default {
  config() {
    return {
      name: "mnb-extraction",
      region: "eu-central-1",
    };
  },
  async stacks(app) {
    const { DeployInfra } = await import("./stacks/deploy-infra");
    const { config } = await import("./config.js");
    // Same pattern as prod: {stage}-{subdomainName}-infra. Do not use stagingSiteLabel here —
    // the hostname label is staging-{sub}, which would double "staging" with app.stage.
    app.stack(DeployInfra, {
      stackName: `${app.stage}-${config.subdomainName}-infra`,
    });
  },
};

