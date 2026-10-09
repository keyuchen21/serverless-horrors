const { onObjectFinalized } = require("firebase-functions/v2/storage");
const { getStorage } = require("firebase-admin/storage");

// Bad: writes the thumbnail back to the same bucket, which fires this trigger again.
exports.thumbnail = onObjectFinalized(async (event) => {
  const bucket = getStorage().bucket(event.data.bucket);
  await bucket.upload("/tmp/thumb.jpg", { destination: event.data.name + ".thumb.jpg" });
});
