const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

const s3 = new S3Client({});

// Bad: writes to the same bucket and has no prefix filter, so each write fires the function again.
exports.resize = async (event) => {
  for (const record of event.Records) {
    await s3.send(new PutObjectCommand({
      Bucket: record.s3.bucket.name,
      Key: "resized-" + record.s3.object.key,
      Body: "...",
    }));
  }
};
