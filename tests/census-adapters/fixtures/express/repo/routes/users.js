const router = require('express').Router();
router.get('/users', list);
router.get('/users/:id', show);
router.put('/users/:id', update);
router.delete('/users/:id', remove);
userRouter.patch(`/users/:id/avatar`, avatar);
module.exports = router;
