const express = require('express');
const app = express();
app.get('/', (req, res) => res.send('ok'));
app.post("/login", login);
app.use('/api', userRouter);
app.listen(3000);
